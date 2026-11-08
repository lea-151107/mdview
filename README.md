# mdview

Vim の画像表示機能（`+image` の popup image）を使い、mermaid・ディスプレイ数式・画像を
描いた状態で Markdown を読めるビューアです。`:Mdview` で右に（`:Mdview here` で同じウィンドウに）
開きます。Markdown のファイル自体は普段どおりのエディタで開きます。

- 引用・リストの中のブロック、参照形式やリンク付きの画像、HTML の `<img>`、文中・表の中の画像も描く（goldmark で解析）
- インライン数式 `$…$` を `x²` のような 1 行のテキストにする
- 編集中も描き直す。時間のかかる図は後から出し、ほかのブロックを先に表示する
- BMP・SVG（rsvg-convert）・http(s) の画像（`g:mdview_remote`）

- mermaid: [dam](../dam)（pure Go）
- 数式: [dal](../dal)（pure Go）
- Vim との連携: [goda.vim](https://github.com/Shougo/goda.vim)

## 導入

```vim
set runtimepath+=~/vim_markdown_viewer/deps/goda.vim
set runtimepath+=~/vim_markdown_viewer/mdview
```

Vim で `:MdviewBuild` を実行します（または `cd go && go build -o ../bin/mdview .`）。

詳しくは `:help mdview` を見てください。

## 構成

```
plugin/mdview.vim     コマンド
autoload/mdview.vim   ビューアバッファ・popup・スクロールの追従
go/                   goda プラグイン（goldmark での抽出・描画・キャッシュ）
test/                 Vim script のテスト（vim -es で動かす）
doc/mdview.txt        ヘルプ
testdata/             確認用の Markdown
```

## テスト

```sh
make check   # gofmt・go vet・staticcheck・Go のテスト・Vim script のテスト
make build   # bin/mdview
echo '{"method":"goda.plugins"}' | ./bin/mdview --transport=jsonl
```

確認用の文書: `testdata/full.md`（書式・図・数式・画像の一覧）、`testdata/nested.md`（入れ子と文中の要素）
