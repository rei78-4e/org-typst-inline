# org-typst-inline

Org バッファ内の Typst 断片を SVG としてインライン表示し、カーソルが要素に入ると生テキストに戻すマイナーモードです。表示の切り替えは org-appear と同じ規則で動くので、強調記号・リンク・Typst 断片が統一された挙動になります。

## 対象

| 要素 | 例 | 表示 |
| --- | --- | --- |
| インライン数式 | `$x^2$`, `\(x^2\)` | 行内に `:ascent center` で表示 |
| ディスプレイ数式 | `\[ sum_(i=1)^n i \]`, `$$ ... $$`, `\begin{equation} ... \end{equation}` | 中央寄せで別行に表示 |
| export snippet | `@@typst:#emoji.face@@` | 画像として描画するか、Nerd Fonts のグリフ1文字に畳む |

数式の中身は Typst 記法として扱います（ox-typst の `org-typst-from-latex-with-naive` と同じ前提）。src / example ブロック、コメント、`=verbatim=`、`~code~` の中にあるものは対象外です。`\foo{bar}` のような LaTeX コマンド形式の fragment も無視します。

## 動作

- jit-lock で可視範囲だけを走査します。編集があったときは、変更された要素の overlay だけを作り直します。
- `typst compile --format svg - <file>` を非同期で実行し、終わるまではプレースホルダを表示します（デフォルトではソースを薄く表示）。
- 文字色とサイズは `default` face から取得します。テーマを切り替えると自動で再描画します。
- `text-scale-mode` に合わせて画像の `:scale` を変えます。
- キャッシュキーは「ソース・色・サイズ・プリアンブル」の SHA-1 です。結果はメモリと `org-typst-inline-cache-directory` に保存します。
- コンパイルエラーになった要素は `org-typst-inline-error` face で表示し、エラー内容を help-echo（マウスを乗せると出るツールチップ）に出します。
- 表示切り替えの単位は `org-element-context` が返す要素の範囲です。閉じ区切りの直後にカーソルがある場合も「中」とみなします。
- org-appear を読み込んでいる場合は、`org-appear-trigger`（`always` / `on-change` / `manual`）、`org-appear-delay`、`org-appear-manual-linger` の設定に従います。`org-appear-manual-start` / `org-appear-manual-stop` にも連動します。
- org-appear がない場合は、`org-typst-inline-trigger`、`org-typst-inline-delay`、`org-typst-inline-manual-linger` と、コマンド `org-typst-inline-manual-start` / `-stop` で同じことができます。
- `org-fragtog-mode` と同時に有効になっているときは警告を出します。

## コマンド

- `org-typst-inline-mode`: マイナーモード
- `org-typst-inline-refresh`: バッファ全体を再描画する（エラーになった要素も再コンパイル）
- `org-typst-inline-clear-cache`: メモリとディスクのキャッシュを削除して再描画する

## 主なカスタマイズ変数

| 変数 | デフォルト | 説明 |
| --- | --- | --- |
| `org-typst-inline-typst-program` | `"typst"` | typst の実行ファイル |
| `org-typst-inline-preamble` | `""` | テンプレートの後に挿入する Typst（フォント指定など） |
| `org-typst-inline-scale` | `1.0` | `default` face の高さに掛ける倍率 |
| `org-typst-inline-snippet-display` | `image` | snippet の表示方式（`image` / `glyph`） |
| `org-typst-inline-snippet-glyph` | `""` | `glyph` のときに表示する文字（nf-fa-code） |
| `org-typst-inline-placeholder` | `nil` | コンパイル中の表示（`nil` ならソースを薄く表示） |
| `org-typst-inline-cache-directory` | `~/.config/emacs/org-typst-inline/` | SVG キャッシュの保存先 |
| `org-typst-inline-max-processes` | `4` | 同時に動かす typst プロセスの数 |
| `org-typst-inline-follow-org-appear` | `t` | org-appear の設定に従うかどうか |

## 設定例

`use-package` の `:vc` キーワード（Emacs 30 以降）で GitHub から直接インストールできます。Emacs 29 では `M-x package-vc-install RET https://github.com/rei78-4e/org-typst-inline` を実行してください。

### org-appear と併用する

```elisp
(use-package org-appear
  :hook (org-mode . org-appear-mode)
  :custom
  (org-appear-autoemphasis t)
  (org-appear-autolinks t)
  (org-appear-trigger 'manual))

(use-package org-typst-inline
  :vc (:url "https://github.com/rei78-4e/org-typst-inline" :rev :newest)
  :hook (org-mode . org-typst-inline-mode)
  :custom
  (org-typst-inline-preamble
   "#set text(font: \"New Computer Modern\")
#show math.equation: set text(font: \"New Computer Modern Math\")")
  :config
  ;; With `org-appear-trigger' set to `manual', previews follow these too.
  (with-eval-after-load 'evil
    (add-hook 'evil-insert-state-entry-hook #'org-appear-manual-start)
    (add-hook 'evil-insert-state-exit-hook #'org-appear-manual-stop)))
```

`org-appear-trigger` が `always` のままなら、evil のフックは不要です。

### ox-typst と併用する

```elisp
(use-package ox-typst
  :after org
  :custom
  ;; These are the defaults; the preview assumes the same naive conversion.
  (org-typst-from-latex-environment #'org-typst-from-latex-with-naive)
  (org-typst-from-latex-fragment #'org-typst-from-latex-with-naive))

(use-package org-typst-inline
  :vc (:url "https://github.com/rei78-4e/org-typst-inline" :rev :newest)
  :hook (org-mode . org-typst-inline-mode)
  :custom
  ;; Fold export-only snippets such as @@typst:#pagebreak()@@.
  (org-typst-inline-snippet-display 'glyph))
```

## テスト

```sh
emacs -Q --batch -L . -l test/org-typst-inline-test.el -f ert-run-tests-batch-and-exit
```

`typst` が PATH にない環境では、実際にコンパイルするテストはスキップされます。
