# Smart Report Builder 現状報告

- 日付: 2026-11-17
- 対象: `main` の `06e6876`（Initial commit of Smart Report Builder）
- 正本: `REQUIREMENTS.md` 1.0、`AGENTS.md`、`CODEX_START_PROMPT.md`
- この変更: アプリケーションコードは触っていない。この報告だけを追加している。

## 結論

1枚のスライドに意味付き画像枠・説明文・矩形 ROI を置き、同じ `LayoutResult` から編集可能な `.pptx` を書く縦切りは動いている。Python のテストは 127 件成功、1 件は Windows のドライブ文字専用でスキップ。デモの `output/sample_a.pptx`、`sample_roi.pptx`、`sample_zooms.pptx` は、テキストボックス、ネイティブ矩形、画像オブジェクトが別々の図形として入っている。

一方、所有者が毎回時間を使っている「画像や見解をまとめる作業」には、まだ距離がある。毎回同じ型を使うところまでは、組み込みの 2 種類の内容型と評価レポートの縦横テンプレートがある。どの画像をどのスライドのどの枠へ置くかは、いま開いているスライドの空枠へ 1 枚ずつ決める作業のままである。見解文はマスターに固定の説明文として入っており、画面から書けない。

最小の第一歩は、新しい画面を足す前に、既存の `assignment_candidates` を広げることである。ファイル名の役割語と、同じフォルダ内の並びから、空いている枠への候補を出す。候補は選ぶまで `Binding` を書かない。これだけで、右クリックの「候補」に載る。

## 1. 実行結果

### Python

この環境の初期状態では `python3.12-venv` が無く、`python3 -m venv` が失敗した。`python3.12-venv` を入れてから次を実行した。

```text
python3 -m venv /workspace/.venv
/workspace/.venv/bin/pip install -e ".[dev]"
/workspace/.venv/bin/pytest -q --tb=line
```

- Python 3.12.3
- 導入した実体: smart-report-builder 0.1.0（editable）、python-pptx 1.0.2、Pillow 13.0.0、pytest 9.2.0
- 結果: **127 passed, 1 skipped**（収集 128 件、3.1 秒、失敗 0）
- スキップ: `tests/test_project_store.py::test_path_on_another_drive_stays_absolute`
  - 理由: `drive letters are specific to Windows`（`os.name != "nt"`）

`.venv/` とデモ出力の `output/` は `.gitignore` 済みで、この報告の差分には入っていない。

### デモと PPTX の中身

`python -m smart_report_builder.demo` は成功し、元 PNG を書き換えずに次を書いた。

| ファイル | 要素 | 違反 | スライド |
|---|---|---|---|
| `output/sample_a.pptx` | 3 | 0 | 1 |
| `output/sample_roi.pptx` | 4 | 0 | 1 |
| `output/sample_zooms.pptx` | 6 | 0 | 1 |

いずれも再読込後の `LayoutResult` が元の配置と一致している。スライドサイズは 12192000 x 6858000 EMU（960 x 540 pt、16:9）。

`ppt/slides/slide1.xml` を展開して確認した。グループ図形（`p:grpSp`）は 0 件。図形はスライド直下に並ぶ。

`sample_a.pptx`:

- `p:sp` の矩形（`prst="rect"`）が「全体画像」「比較画像」
- `p:sp` かつ `txBox="1"` のテキストボックスが「説明」。本文は `DEFAULT_CAPTION` の全文
- `p:pic` が「全体画像（画像）」「比較画像（画像）」。枠の矩形とは別オブジェクトで、埋め込みも `ppt/media/image1.png` と `image2.png` の 2 つ
- 画像の位置は枠より小さい。Contain の描画矩形がそのまま EMU になっている

`sample_roi.pptx`:

- 枠 2 つ、テキストボックス 1 つ、ROI の矩形 1 つ、`p:pic` 2 つ
- 全体画像と拡大画像は別の `p:pic`。両方とも同じ `r:embed="rId2"` を指し、メディアは元 PNG 1 枚
- 拡大側だけ `a:srcRect` が `l=10000 t=20000 r=70000 b=20000`（左 10%、上 20%、右 70%、下 20%）。正規化 ROI `(0.1, 0.2, 0.2, 0.6)` のトリミングと一致する
- 全体側の `p:pic` に `srcRect` は無い。元画像の画素ファイルは切っていない

`sample_zooms.pptx` は枠 3、画像 3、ROI 矩形 2、説明 1。拡大 2 つもそれぞれ独立した `p:pic`。

デモの ROI は注釈が空なので、接続線と表はこの 3 ファイルには無い。接続線は `pptx_writer._add_connector` が `p:cxnSp`（直線）と始点側の三角矢印を書く実装で、表は `tests/test_practical.py` がネイティブテーブルの出力を検証している。デモ単体では矢印と表は見ていない。

### Flutter

`flutter` と `dart` は PATH に無く、`/opt`、`/usr/local`、`/home/ubuntu` にも SDK は無かった。`flutter analyze` と `flutter test` は実行していない。

プレビューは Flutter プロジェクトとしては揃っている。

- `preview/pubspec.yaml`: SDK `^3.12.0`、パッケージ名 `smart_report_preview`。依存は `archive` と `desktop_drop`
- `preview/windows/` に Windows ランナーがある
- テストは `preview/test/` に 9 ファイル（`slide_preview_test.dart` 1178 行、`roi_links_test.dart` 525 行など）。この環境では未実行
- 画面は `preview/lib/main.dart` の `PreviewHome` 1 枚（4630 行）。要件 3.1 のホーム／素材／マスター／レポート／出力という画面分割にはなっていない

## 2. Flutter と Python のつながり

方式は決まったあと実装されている。ローカルの長寿命プロセスと、標準入出力の 1 行 JSON である。HTTP ではない。

1. Flutter の `ReportSession`（`preview/lib/roi_persist.dart`）が `Process.start` で次を起動する。

   `python -m smart_report_builder.roi_edit session`

   環境変数は `PYTHONIOENCODING=utf-8` と `PYTHONUTF8=1`。
2. 起動先は `edit_session.serve`。stdin の 1 行が 1 要求、stdout の 1 行が 1 応答。操作は `open`、`run`、`save` の 3 つ。
3. `run` は既存の `roi_edit.main(argv)` を同じプロセスで呼ぶ。`load_project` と `_save_outputs` をフックし、編集はメモリ上の `Project` に溜める。`project.json`、`layout.json`、`report.pptx` は `save` まで書き換えない。
4. 応答には `ok`、`code`、キャプチャした `stdout`/`stderr`、`dirty`、プロジェクト JSON、`LayoutResult` JSON が入る。プレビューはその `layout` を描く。
5. 操作は直列。応答待ちは 3 分で打ち切る。

Python の場所は Windows 専用の探索である。`pythonExecutableNearLayout` は、配置 JSON の 2 つ上、またはカレントの親にある `.venv/Scripts/python.exe` だけを見る。`python3` や PATH 上の Python は使わない。ファイル選択、フォルダ選択、タスクファイル選択は `powershell.exe` の `System.Windows.Forms` である。

この Linux 環境では、Flutter SDK が無いことに加えて、プレビューが Python を見つけられず、ダイアログも開かない。計算コアの試験は Python 側で完結している。

## 3. MVP 1 と受入基準

判定は次の意味で付けた。

- **done**: その項目の縦切りがコードとテストで通る
- **partial**: 核はある。項目が求める範囲の一部が別画面、別データ、または未接続のまま
- **missing**: 対応する型か操作が無い

### 10 章 MVP 1

| 項目 | 判定 | 根拠 |
|---|---|---|
| プロジェクト新規作成・保存・再読込 | done | `project_factory.create_report`、`project_store.save_project` / `load_project`、`roi_edit._new_project`。素材パスはプロジェクトからの相対パス。テストは `tests/test_project_store.py`、`tests/test_project_factory.py`、`tests/test_edit_session.py`。画面は新規ダイアログと「保存」 |
| 画像 2〜4 枚と説明文のマスター | done | `create_report` は 2〜4 枚、横・縦・格子、「画像と説明」「全体と拡大」。説明文は `TextNode`。5 枚以上の一括作成は拒否し、枠の追加は 1 つずつ。マスター専用の 3 タブ画面は無く、同じプレビュー上で木を編集する |
| 意味付き画像枠、簡易素材登録、手動割当 | partial | 枠の `role_id` は `overall` / `comparison` / `zoom` / `image`。表示名と role は `set_image_frame_kind` がセットで書き換える。役割カタログのカスタムは無い。登録は `register_folder_images` とドラッグ、ライブラリからの割当。自動では入らない |
| Vertical / Horizontal / Grid の自動追従 | done | `layout._place_stack` / `_place_grid`。`track_aspect` で隣の枠が縦横比に追従する（`tests/test_project_factory.py`）。すべての子が画像枠で `free_rect` を持つと、その親は等分をやめ自由配置になる |
| 仮プレビューと実データプレビュー | done | `preview_mode_of` が通常枠だけを見て `provisional` / `partial` / `real`。未割当でも枠と全文を残す。Flutter は `previewMode` を表示する。この環境では画面の見た目は未確認 |
| 矩形 ROI を 1 つ、拡大枠へ連動 | done | `FitMode.ROI`、`layout._apply_rois`、`roi_edit` の作成・移動・リサイズ・複製・削除・連動。正規化とピクセルの両方。テストは `tests/test_layout.py` と `tests/test_roi_edit.py` |
| PPTX へ画像・文字・ROI 枠を独立要素で出力 | done | `pptx_writer.write_pptx` は `LayoutResult` の座標を再計算しない。上記の XML 確認と `tests/test_pptx_writer.py`、`tests/test_pptx_spike.py` |
| 最低限のエラー表示と座標の単体テスト | done | 違反は `overflow`、`overlap`、`unassigned_image`、`missing_asset`、`binding_conflict`、`roi_out_of_bounds` など。画面は `code: message` の文字列。座標テストは `tests/test_units.py`、`tests/test_fit.py`、`tests/test_layout.py` |

MVP 1 の縦切りは完了と見てよい。残っているのは、その縦切りを「毎回の報告書作り」の操作にすることである。

### 11 章 受入基準

| # | 基準 | 判定 | 根拠 |
|---|---|---|---|
| 1 | 画像が無くても全体・拡大・文章の枠を設計できる | done | `test_overall_and_zoom_can_be_created_before_any_image_is_registered`。未割当の PPTX は枠とテキストだけで画像が 0 枚（`test_unassigned_master_exports_frames_and_text_without_pictures`） |
| 2 | 同じマスターへ 3・4・6 枚の Dataset を適用し、統一と例外提案 | partial | 新規作成は 2〜4 枚。はみ出したとき `propose_variants` が標準・等分・主画像・格子から最大 3 件を返し、選ぶまで木を変えない。6 枚の Dataset を一括適用する経路は無い。Dataset は評価対象ではなく素材 ID の一覧 |
| 3 | 画像サイズ変更で後続が追従し、固定制約違反を検出 | partial | 縦横比追従と、枠が 48 pt 未満・スライド外・重なりの検出はある。`preferredSize` / `minSize` / `maxSize` はモデルに無い。文字切れは枠の高さ超過であり、字形の溢れは測っていない |
| 4 | Contain で元画像が切れず縦横比が変形しない | done | `fit.contain_rect`。`cover` は `UnsupportedFitModeError` で停止する。PPTX の拡大は `srcRect` で、元ファイルは別オブジェクトのトリミング。ドラッグ中の仮矩形だけ、後述のとおり縦横を別倍率で縮める |
| 5 | ROI 編集で拡大プレビューが更新される | done | 確定後に `layout_slide` が拡大枠の `content_rect` と `crop` を計算し直す。Flutter は確定までローカルに枠を動かし、離したとき Python へ正規化座標を送る |
| 6 | 標準 ROI を複数 Dataset へ展開し、一部だけ補正して保持 | partial | `apply_master_roi` は選んだ画像枠へ継承で足し、`relative_override` と `detached` はスキップする。対象は 1 プロジェクトの枠であり、Dataset 単位の展開画面は無い |
| 7 | マスター ROI 更新で継承・補正・個別が分かれる | done | `layout._effective_roi` と `practical.record_roi_move`。`tests/test_practical.py::test_master_roi_inheritance_and_batch_keep_corrections` |
| 8 | 元画像、別解像度、画像外 ROI、不明な座標対応 | partial | ピクセル ROI、画像外は適用せず違反、寸法不正、素材欠落のテストはある。EXIF 回転の正規化は無い。`coordinate_transform` という関係自体が無い |
| 9 | PPTX で文字・枠・矢印が別オブジェクト | partial | デモで文字・枠・画像・ROI 矩形は確認した。矢印は注釈があるときのコネクタであり、デモ出力には含まれない。表は別テストでネイティブ `a:tbl` |
| 10 | 再読込でマスター、バインディング、選択レイアウト、ROI 補正を復元 | partial | 単一スライドの往復はテスト済み。複数スライドは `layouts` / `slides` / `activeSlideId`。スライドが 1 枚に戻るとその配列は JSON から落ちる。選んだレイアウト案は木を書き換えた結果として残り、案の ID は残らない |
| 11 | プレビューと PPTX が同一座標 | partial | 確定後は同じ `LayoutResult` を JSON と PPTX が使う。Flutter は配置を再計算しない、という契約。ドラッグ中は Dart が矩形を書き換える。ヘッダーはプレビューが `chrome.png`、PPTX がテンプレートの図形。Dart と PPTX を同じ座標で突き合わせるテストは、この環境では実行していない |
| 12 | 手動変更が再生成で消えそうなとき警告し、無断で上書きしない | partial | 未保存ダイアログ、新しい保存より古い PPTX 書き出しの拒否、補正済み ROI の保護はある。レイアウト案の適用は `free_rect` を消す。空のスライド追加やフォルダ登録に、手修正との衝突確認は無い |

### MVP 2 以降で、すでに手を付けてあるもの

要件 10 章の MVP 2 は「未着手」ではない。範囲が狭い。

- フォルダ一括登録: `register_folder_images`。割当はしない。サブフォルダの表示名は `親/ファイル名`
- 自動割当候補: `practical.assignment_candidates`。下記 5 章
- レイアウト案: はみ出しのときだけ、最大 3 件。スコアは無い
- ROI の継承・一括展開・相対補正: 1 スライドの枠に対して実装済み。展開 UI は右クリック
- 表: 1 個、行と列の追加、セル文字は短縮しない。PPTX はネイティブ表
- 操作履歴: メモリと `project.json.history.json`。最大 20 段。保存までディスクの本編は変わらない
- 評価レポートの縦横: `templates/jp_portrait.pptx` と `jp_landscape.pptx`。`Slide_Image` の本文だけを書き、ほかのスライドは残す
- 既存 PPTX の取り込み: `open_pptx_preview` は撮像スライドの枚数だけ空の枠を作る。図形のコンポーネント変換ではない
- 未着手のまま: `same_subject` / `derived_from` / `coordinate_transform`、実寸 scale lock、Repeater、AI、外部送信

## 4. 設計上の大きいリスク

### 座標は 3 系統ある。確定後の配置は揃う

論理座標はスライド左上原点のポイント。PPTX は `units.pt_to_emu`（1 pt = 12700 EMU、四捨五入）。ROI の原本は元画像の正規化座標（0〜1）かピクセルで、表示位置は Contain 後の `content_rect` へ写す。画面の拡大と移動は `PreviewView` が行い、キャンバス自体はポイントサイズの `SizedBox` を `FittedBox` している。ドラッグのヒットは、そのキャンバスのローカル座標をポイントとして扱う。

崩れる箇所はドラッグ中の仮表示である。`layout_result.dart` の `scaleContainedRect` は、枠の幅の倍率と高さの倍率を別々に中の画像へ掛ける。幅だけ変えると、確定前のプレビューは縦横比が崩れて見える。離したあとの `resize-frame` は Python が Contain を計算し直す。確定に失敗したまま見ていると、プレビューと次の PPTX が一致しない。

注釈の接続線も二箇所にある。Python の `layout._connector_points` と Dart の `note_geometry.connectorEnds` は同じ規則の写しである。片側だけ直すと、ドラッグ中の線と保存後の線がずれる。

EXIF の向きは正規化していない。`Image.open` の `size` をそのままピクセル座標の分母にしている。回転フラグ付きの写真は、ROI のピクセル位置が撮影時の見た目とずれる。

### プレビューと PPTX は同じ `LayoutResult` を契約にしている

`layout.layout_slide` は UI も python-pptx も import しない。`write_pptx` は渡された矩形を EMU にするだけである。Flutter の `LayoutResult.fromJson` も配置の再計算をしない。未知の `kind` は Flutter が読み飛ばして `skippedElementIds` に出し、Python は拒否する。契約の端が違う。

テンプレート使用時、本文の枠は `LayoutResult`、タイトルはテンプレート上の既存図形の文字差し替え、プレビューのヘッダーはラスタの `chrome.png` である。本文座標は共有できても、タイトルとヘッダーの見た目は別経路である。

### 型の分離は始まっている。スライドごとの中身がマスター側に残っている

`DesignMaster`、`ContentMaster`、`Asset`、`Binding`、`SlideInstance`、`Roi`、`MasterRoi`、`Dataset`、`LayoutDefinition`、`ReportSlide` は別の dataclass である。`LayoutVariant` という型は無く、案は `LayoutProposal` の一時オブジェクトで、採用すると `ContentMaster` の木を直接書き換える。

`Project` は「いま編集中の `content_master` と `slide`」と「デッキの `layouts` と `report_slides`」を両方持つ。アクティブ化は同じオブジェクトを指すので、メモリ上は同期する。保存時、スライドかレイアウトが 2 つ以上のときだけ `layouts` / `slides` を JSON に書く（`models.project_to_dict`）。1 枚に戻すとデッキを解体する。ここを壊すと、単一スライドの古いファイルと複数スライドのファイルで読込経路が分岐したままになる。

見解と表がマスター側にあるのが、報告書作りとの衝突である。

- 説明文の初期値は `ContentMaster` の `TextNode.text`。レイアウトを共有するスライドは、この文字列を共有する
- `Binding.text` があればレイアウトはそちらを使う（`layout._place_text`）。書くコマンドが無い
- 表のセルも `TableNode` がマスター上に持つ。共有レイアウトのスライド間でセルが共通になる
- 画像の割当と ROI は `SlideInstance` 側なので、スライドごとに分かれる

`schemaVersion` はプロジェクト、デザイン、内容マスター、`LayoutResult` のすべてが整数 `1` で、不一致は即エラーである。移行関数は無い。バージョン 1 の中では、古い `pages` キーを `layouts` と `slides` へ読み替える処理だけがある。フィールドを足すときは、未知キーを無視する今の読込なら古いファイルは開く。必須フィールドを足した瞬間に既存の `project.json` は開けなくなる。

### 操作の出入口が 1 本の CLI に集中している

`roi_edit.main` は約 40 コマンドの分岐で、2472 行ある。Flutter 側の対応する手続きも `roi_persist.dart`（1682 行）と `main.dart`（4630 行）に並ぶ。セッションはコマンドの標準出力をキャプチャしているが、`serve` の待ち受け中に素の `print` が stdout へ出ると、1 行 JSON のプロトコルが壊れる。

履歴ファイルはプロジェクト JSON の兄弟 `*.history.json` で、スキーマの外にある。プロジェクトだけコピーすると Undo が消える。

## 5. 画像と見解をまとめる作業から見た使い心地

目標は「画像検査レポートを柔軟に、効率よく、ストレスなく作る」ことである。いまの実装が減らしているストレスは、配置の計算、Contain、ROI の拡大、PPTX が編集できること、未保存をメモリに留めることである。毎回残るストレスは、画像を枠へ配ることと、見解を書き付けることである。

### いまのコードが、その作業のどこまで届いているか

**テンプレートの再利用。** 届いているのは「空の型を選んで新規フォルダへ書く」まで。新規ダイアログは用紙（16:9 / 評価レポート縦 / 横）、内容（画像と説明 / 全体と拡大）、枚数（2〜4）、並び（横 / 縦 / 格子）の 4 つと、保存先フォルダである。評価レポートを選ぶと、同梱 PPTX をプロジェクトへコピーし、本文領域へ枠を置く。プロジェクトの中では「スライドを追加」が現在のレイアウトを空の割当でもう 1 枚作る。右クリックには「レイアウトを追加: 画像2枚 横」のような定番も並ぶ。

届いていないのは、前回の報告書や、自分で直したマスターを名前付きで残し、次の案件でその 1 つを選ぶ操作である。型の実体はコード内の `create_report` と 2 つの PPTX だけで、ユーザーが保存した型の一覧は無い。

**どの画像をどのスライドへ置くか。** ライブラリ（`image_library.dart`）はフォルダ、複数ファイル、`C:\viscotech\task` の group/task、タスク圧縮ファイルを、このセッションの一覧に出す。VTV のパスは `g01/03` のようなラベルにまとまる。上限は 2000 枚。この一覧はプロジェクト JSON に入らない。アプリを閉じると、まとめた結果は消える。

プロジェクトへの登録（`register_folder_images`）はパスと寸法と表示名を足すだけで、枠へは入れない。表示名は直下のファイルなら stem、サブフォルダなら `親/stem`。`Dataset` は名前と素材 ID の配列で、右クリックから手で出し入れする。スライドも画像も作らない。

自動候補（`practical.assignment_candidates`）は、いまのスライドの空の通常枠だけを見る。

- 枠の表示名または `role_id` と、素材の表示名またはファイル名 stem が完全一致し、候補が 1 つなら `ready`
- 完全一致が複数、または 2 文字以上の部分一致なら `confirm`
- 採用するまで `Binding` は書かない。採用は `assign_registered_asset`

ファイル名が `全体画像` や `overall` のときは候補になる。`g01/03/img/cam_a.bmp` や `処理後_01.png` は、枠の名前が「全体画像」「比較画像」のままでは候補にならない。フォルダ単位で「このフォルダは 1 枚のスライド」と決める処理も、過去の `project.json` の割当を覚える処理も無い。役割の推論は、表示名の文字列一致だけである。

手作業の経路は、枠を選んでライブラリの画像を割り当てる、枠へファイルをドロップする、右クリックで「未割当を入れる」である。右クリックは未割当の素材 1 つにつき項目が 1 つ増える。フォルダ登録のあとに枚数が多いと、メニューそのものが一覧になる。

新しいスライドは `add_slide` がレイアウトを共有し、`SlideInstance` の bindings と rois は空である。10 枚の画像を 5 枚のスライドへ配るには、スライド追加と枠への割当を枚数ぶん繰り返す。

**見解。** 説明枠の文言は `demo.DEFAULT_CAPTION`（「これは編集可能な説明文です。…」）がマスターに入ったままである。プレビューに、この文章を編集する欄は無い。`kind == 'text'` の右クリック項目も無い。編集できる文字は、撮像テンプレートのページタイトル、ROI の注釈ダイアログ、表のセルダイアログである。いずれも「この画像についての見解」を、画像の隣へ続けて書く操作にはなっていない。

データとしては `Binding.text` がスライド側の上書きとして既に読まれる。ここへ書く口が無いので、画面からはマスターの固定文しか出ない。レイアウト共有のスライドは、その固定文も表も一緒に変わる。

### その結果として残る痛み

1. 案件のたびに、型を 4 項目選んでから、画像を 1 枠ずつ置いている。型は毎回ほぼ同じなのに、選択が残る。
2. フォルダや VTV の group/task で画像は既にまとまって見えるのに、そのまとまりがスライドにならない。
3. 候補は名前が枠ラベルと一致したときだけなので、実ファイル名では候補が空のまま、手作業に戻る。
4. 見解を書く場所が、説明枠ではなく ROI 注釈か表セルに散っている。画像 1 枚についての一文を、その場で確定できない。
5. 説明文と表がマスター共有なので、2 枚目のスライドで文章を直すと 1 枚目まで変わる、という事故が、文章編集を足した瞬間に起きる。
6. ライブラリの整理はセッション限りなので、翌日も同じフォルダを開き直す。
7. 操作の大半が 1 つの右クリックに入っている。戻す、スライド、割当、共有、削除、ROI、表が同じメニューで、枚数が増えると項目も増える。
8. 違反はプレビュー上の 1 つの文字列である。未割当が何枚あるか、どのスライドが空か、を一覧で見て直す画面が無い。
9. 保存は JSON と PPTX を同時に書く。編集可能ではある。書いたあとに PowerPoint 側で直した文字や枠を、プロジェクトへ戻す経路は無い（要件上、PPTX からの完全復元は約束していない。見解を PowerPoint だけで直すと、次回の書き出しで戻る）。

柔軟さは、枠の追加、種類の変更、自由矩形、レイアウトの追加、素材の共有として既にある。効率と安心は、配分と文章が手作業のままなので、まだ縦切りの範囲に留まっている。

## 6. 次の実装タスク

優先は「同じ型へ、画像を配り、見解を付ける」である。配置エンジン、AI、既存 PPTX のコンポーネント変換、位置合わせは、この列の後ろに置く。各タスクは、採用前の候補か、1 スライド分の文字か、どちらかに範囲を切る。既存の手修正は、明示して選んだときだけ上書きする。

### 1. 役割語とフォルダ順の割当候補（最初の一歩）

`practical.assignment_candidates` を広げる。空の通常枠に対し、ファイル名と親フォルダ名から役割語を探す。語彙の初期値は `全体` / `overall`、`比較` / `comparison`、`拡大` / `zoom`、`処理` / `processed` と、枠の `display_name`。1 対 1 のときだけ `ready`、複数なら `confirm`。役割語が無い画像は、同じ親フォルダのものをファイル名順に、そのスライドの空枠へ `confirm`（理由は「同じフォルダの並び」）として出す。関数は `Binding` を書かない。既存の完全一致も残す。UI は今の「候補:」項目のまま載る。

完了: `tests/test_practical.py` に、プロジェクトの bindings が関数の前後で同じこと、`全体_01.png` が `overall` の空枠へ `ready` になること、同じ語が 2 枚あると `confirm` のままどちらも入らないこと、無関係な名前は未割当のままであること。

### 2. 開いている型で、空の報告書を 1 コマンドで作る

`roi_edit` に、既存の `project.json` を型として新しいディレクトリへコピーする操作を足す。コピーするのは `DesignMaster` と `ContentMaster` の木（枠、説明枠、表の形、マスター ROI）。素材、bindings、スライドの ROI、ページタイトルの案件固有値は空にする。説明文の初期値は固定のデモ文を繰り返さず、空文字にする。新規ダイアログの 4 選択は、型を指定しなかったときだけ使う。

完了: 元の `project.json` がバイト単位で変わらないこと、新しいプロジェクトが画像なしで開け、枠の ID と role が元と同じこと、bindings が空のこと。テストは上書き拒否（既存の `new-project` と同じ）を含む。

### 3. スライドごとの見解を `Binding.text` で書く

説明枠の文字を、マスターの `TextNode` ではなく、その `SlideInstance` の `Binding.text` に保存するコマンド `set-text` を足す。レイアウトは既に `Binding.text` を優先するので、配置計算は変えない。プレビューでは説明枠をクリックすると、その場の欄に全文が出て、確定で `set-text` を呼ぶ。短縮やトリムはしない。レイアウトを共有する隣のスライドの binding は変えない。

完了: 2 スライドが同じレイアウトを共有する状態で、1 枚目の文章だけが変わり、2 枚目はマスターの文のままであること。保存、再読込、PPTX のテキストボックスに同じ全文が入ること。空文字も保存できること。

### 4. フォルダ 1 つを、スライド案 1 枚にする

登録済み素材を親フォルダ（VTV なら `image_library.dart` の `g01/03` と同じ規則）で分け、タスク 2 の型の空スライドをフォルダごとに提案する。各スライドの中の枠への対応はタスク 1 の候補を使う。提案オブジェクトを返すだけで、`report_slides` は増やさない。採用関数は、ユーザーが選んだフォルダだけスライドを足し、候補のうち `ready` だけを割り当て、`confirm` は未割当のまま残す。

完了: フォルダ 2 つで提案が 2 件になること、採用前のプロジェクトが変わらないこと、採用後も `confirm` の素材が未割当のままであること、既存スライドの bindings と ROI が残ること。

### 5. 画像 1 枚につき見解 1 つ

タスク 3 のスライド全体の説明に加え、通常枠ごとの短い見解をスライド側に持つ。実装は、その枠 ID に対する `Binding.text` と、プレビュー上の枠の下に出す 1 行の欄とする。マスターの木に、枠の数だけ `TextNode` を増やすと共有レイアウトの全スライドへ枠が増えるので、そちらは採らない。`LayoutResult` には枠に紐づくテキスト要素を 1 つ足し、PPTX では独立したテキストボックスにする。文章は短縮しない。

完了: 同じレイアウトの 2 枚のスライドで、同じ枠 ID の見解が別々に復元されること。未入力の枠はテキストボックスを出さないこと。座標テストで、テキストボックスが画像枠の外にはみ出すとき `overflow` になり、文字列自体は残ること。

### 6. 過去のプロジェクトの割当を候補に足す

同じ親ディレクトリ、またはユーザーが渡したディレクトリにある `project.json` を読み、ファイル名 stem と割り当て先の `role_id` の組を数える。いまの空枠の role と 1 位の role が一致し、その stem の素材が未使用なら `confirm`（理由は「以前の報告書でこの役割」）を足す。2 位がある stem は候補を複数出し、自動では入れない。読み取り専用で、過去ファイルは書き換えない。

完了: 過去に `overall` へ入っていた stem が候補になること、別 role が同数なら `ready` にならないこと、過去ファイルの更新時刻が変わらないこと。一致が無いとき、タスク 1 の結果以外を足さないこと。

### 7. 候補の一括採用と、手修正の前の確認

タスク 1 と 4 の提案に、「ready だけ採用」「このスライドの confirm も採用」を足す。既に `asset_id` が入っている枠と、ユーザーが動かした ROI は対象外にする。対象外が 1 つでもある採用では、消える割当の枠 ID を stderr に列挙して拒否する。強制するフラグを明示したときだけ、その枠の割当を替える。ROI の座標はどちらの場合も変えない。

完了: 既存テストの「拒否した操作はプロジェクトを変えない」と同じ形で、フラグなしの拒否、フラグありでも ROI の数値が同じこと、未割当の ready だけが入ること。

この 7 つのあとで、プレビューの右クリックを「スライド」「画像」「見解」に分け、未割当と空スライドの一覧を出す。それは画面分割であり、上の候補と文章がテストで固定されてからで足りる。AI による分類と、PPTX からのコンポーネント取り込みは、要件どおりこの列の外に置く。

## この報告の範囲

- 実装概要: 調査と、この `docs/STATUS_REPORT.md` の追加のみ
- 変更ファイル: `docs/STATUS_REPORT.md`
- 実行手順: 上記 1 章の venv 作成、`pytest`、`python -m smart_report_builder.demo`、PPTX を ZIP として `slide1.xml` を確認
- 確認したテストと結果: Python 127 passed / 1 skipped / 0 failed。Flutter は SDK が無く未実行
- 未実装と既知の制限: 5 章と 6 章。デモの 3 つの PPTX には接続線と表が無い。プレビューの実機操作はこの環境では未確認
- 次の推奨タスク: 6 章の 1
