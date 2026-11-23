"""編集をメモリに溜め、保存のときだけ JSON と PPTX を書く。

プレビューの各操作は、このプロセスが持っている Project を更新して配置結果を返す。
project.json、layout.json、report.pptx は save まで書き換えない。
"""

from __future__ import annotations

import copy
import io
import json
import sys
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Any

import smart_report_builder.roi_edit as roi_edit
from smart_report_builder.layout import layout_slide
from smart_report_builder.models import layout_result_to_dict, project_from_dict, project_to_dict
from smart_report_builder.project_store import (
    _from_stored_path,
    _to_stored_path,
    load_project,
    save_layout_result,
    save_project,
)
from smart_report_builder.pptx_writer import write_pptx_slides

_DIRECT = {"new-project", "open-pptx", "export-pptx"}
_CURRENT: EditSession | None = None
_INSTALLED = False
_REAL_LOAD = roi_edit.load_project
_REAL_SAVE = roi_edit._save_outputs


class EditSession:
    def __init__(self) -> None:
        self.project = None
        self.project_path: Path | None = None
        self.layout_path: Path | None = None
        self.pptx_path: Path | None = None
        self.result = None
        self.undo: list[bytes] = []
        self.redo: list[bytes] = []
        self.saved_token = b""
        self.active = False
        self._saved_this_run = False
        self._record_undo = True

    def open(self, project_path: str, layout_path: str | None, pptx_path: str | None) -> None:
        self._bind()
        self.active = False
        self.project_path = Path(project_path).resolve()
        self.layout_path = Path(layout_path).resolve() if layout_path else None
        self.pptx_path = Path(pptx_path).resolve() if pptx_path else None
        self.project = load_project(self.project_path)
        history = roi_edit._load_history(self.project_path)
        self.undo = [roi_edit._decode(item) for item in history["undo"]]
        self.redo = [roi_edit._decode(item) for item in history["redo"]]
        self.result = layout_slide(self.project)
        self.saved_token = self._token()
        self.active = True

    def dirty(self) -> bool:
        if not self.active or self.project is None:
            return False
        return self._token() != self.saved_token

    def accepts(self, path: str | Path) -> bool:
        if not self.active or self.project_path is None:
            return False
        try:
            return Path(path).resolve() == self.project_path
        except OSError:
            return False

    def run(self, argv: list[str]) -> dict[str, Any]:
        self._bind()
        if not argv:
            return self._error("操作がありません")
        if argv[0] in _DIRECT:
            return self._direct(argv)
        if argv[0] in {"undo", "redo"}:
            return self._history(argv[0])
        if not self.active or self.project is None or self.project_path is None:
            return self._error("プロジェクトを開いていません")
        before = copy.deepcopy(self.project)
        before_bytes = self._token()
        previous_result = self.result
        self._saved_this_run = False
        self._record_undo = True
        stdout, stderr = io.StringIO(), io.StringIO()
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = roi_edit.main(list(argv))
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
        except Exception as exc:
            self.project = before
            self.result = previous_result
            self._saved_this_run = False
            return self._error(str(exc))
        if code != 0:
            self.project = before
            self.result = previous_result
            self._saved_this_run = False
        elif self._saved_this_run and self._record_undo:
            self.undo.append(before_bytes)
            self.undo = self.undo[-roi_edit._HISTORY_LIMIT :]
            self.redo.clear()
        return self.reply(code, stdout.getvalue(), stderr.getvalue())

    def save(self) -> dict[str, Any]:
        self._bind()
        if not self.active or self.project is None or self.project_path is None:
            return self._error("プロジェクトを開いていません")
        try:
            result = layout_slide(self.project)
            self.result = result
            save_project(self.project, self.project_path)
            if self.layout_path is not None:
                save_layout_result(result, self.layout_path)
            if self.pptx_path is not None:
                prior = self.pptx_path if self.pptx_path.is_file() else None
                write_pptx_slides(
                    roi_edit.layouts_for_pptx(self.project, result),
                    self.pptx_path,
                    prior_path=prior,
                )
            self._persist_history()
            self.saved_token = self._token()
        except Exception as exc:
            return self._error(str(exc))
        return self.reply(0, "saved\n", "")

    def reply(self, code: int, stdout: str, stderr: str) -> dict[str, Any]:
        return {
            "ok": code == 0,
            "code": code,
            "stdout": stdout,
            "stderr": stderr,
            "dirty": self.dirty(),
            "canUndo": bool(self.undo),
            "canRedo": bool(self.redo),
            "project": self._project_payload(),
            "layout": self._layout_payload(),
        }

    def _direct(self, argv: list[str]) -> dict[str, Any]:
        stdout, stderr = io.StringIO(), io.StringIO()
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = roi_edit.main(list(argv))
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
        except Exception as exc:
            return self._error(str(exc))
        return self.reply(code, stdout.getvalue(), stderr.getvalue())

    def _history(self, operation: str) -> dict[str, Any]:
        if not self.active or self.project is None or self.project_path is None:
            return self._error("プロジェクトを開いていません")
        if operation == "undo":
            if not self.undo:
                return self._error("戻せる操作がありません")
            current = self._token()
            previous = self.undo.pop()
            self.redo.append(current)
            self.redo = self.redo[-roi_edit._HISTORY_LIMIT :]
            self.project = _project_from_bytes(previous, self.project_path.parent)
            label = "undone\n"
        else:
            if not self.redo:
                return self._error("やり直せる操作がありません")
            current = self._token()
            nxt = self.redo.pop()
            self.undo.append(current)
            self.undo = self.undo[-roi_edit._HISTORY_LIMIT :]
            self.project = _project_from_bytes(nxt, self.project_path.parent)
            label = "redone\n"
        self.result = layout_slide(self.project)
        return self.reply(0, label, "")

    def _persist_history(self) -> None:
        if self.project_path is None:
            return
        history = {
            "undo": [roi_edit._encode(item) for item in self.undo],
            "redo": [roi_edit._encode(item) for item in self.redo],
        }
        roi_edit._store_history(self.project_path, history)
        roi_edit._mirror_history(self.project_path, history)

    def _token(self) -> bytes:
        if self.project is None or self.project_path is None:
            return b""
        return _project_bytes(self.project, self.project_path.parent)

    def _project_payload(self) -> dict[str, Any] | None:
        if self.project is None or self.project_path is None:
            return None
        payload = project_to_dict(self.project)
        directory = self.project_path.parent
        assets = payload.get("assets")
        if isinstance(assets, list):
            for stored, asset in zip(assets, self.project.assets, strict=True):
                if isinstance(stored, dict) and stored.get("path") is not None:
                    stored["path"] = _to_stored_path(asset.path, directory)
        return payload

    def _layout_payload(self) -> dict[str, Any] | None:
        if self.result is None:
            return None
        return layout_result_to_dict(self.result)

    def _error(self, message: str) -> dict[str, Any]:
        reply = self.reply(1, "", message)
        reply["ok"] = False
        return reply

    def note_save(self, project, record_undo: bool) -> None:
        self.project = project
        self._saved_this_run = True
        self._record_undo = record_undo
        self.result = layout_slide(project)

    def _bind(self) -> None:
        global _CURRENT
        _CURRENT = self
        _install()


def serve() -> int:
    if hasattr(sys.stdin, "reconfigure"):
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
    session = EditSession()
    session._bind()
    for line in sys.stdin:
        text = line.strip()
        if not text:
            continue
        try:
            request = json.loads(text)
            if not isinstance(request, dict):
                reply = session._error("操作の形式が違います")
            else:
                reply = _dispatch(session, request)
        except Exception as exc:
            reply = session._error(str(exc))
        sys.stdout.write(json.dumps(reply, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    return 0


def _dispatch(session: EditSession, request: dict[str, Any]) -> dict[str, Any]:
    operation = request.get("op")
    if operation == "open":
        session.open(
            str(request["project"]),
            request.get("layout"),
            request.get("pptx"),
        )
        return session.reply(0, "opened\n", "")
    if operation == "run":
        args = request.get("args") or []
        return session.run([str(item) for item in args])
    if operation == "save":
        return session.save()
    return session._error("不明な操作です")


def _install() -> None:
    global _INSTALLED
    if _INSTALLED:
        return
    roi_edit.load_project = _hooked_load
    roi_edit._save_outputs = _hooked_save
    _INSTALLED = True


def _hooked_load(path):
    session = _CURRENT
    if session is not None and session.accepts(path):
        return session.project
    return _REAL_LOAD(path)


def _hooked_save(project, project_path, layout_path, pptx_path, record_undo: bool = True):
    session = _CURRENT
    if session is None or not session.accepts(project_path):
        return _REAL_SAVE(
            project,
            project_path,
            layout_path,
            pptx_path,
            record_undo=record_undo,
        )
    session.note_save(project, record_undo)


def _project_bytes(project, directory: Path) -> bytes:
    payload = project_to_dict(project)
    assets = payload.get("assets")
    if isinstance(assets, list):
        for stored, asset in zip(assets, project.assets, strict=True):
            if isinstance(stored, dict) and stored.get("path") is not None:
                stored["path"] = _to_stored_path(asset.path, directory)
    return (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _project_from_bytes(payload: bytes, directory: Path):
    data = json.loads(payload.decode("utf-8"))
    assets = data.get("assets")
    if isinstance(assets, list):
        for asset in assets:
            if isinstance(asset, dict) and asset.get("path") is not None:
                asset["path"] = _from_stored_path(str(asset["path"]), directory)
    return project_from_dict(data)
