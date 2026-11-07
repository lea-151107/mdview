# mdview

Vim の画像表示機能（`+image` の popup image）を使い、Markdown バッファの中に
mermaid・ディスプレイ数式・画像を描くプラグインです。

- mermaid: [dam](../dam)（pure Go）
- 数式: [dal](../dal)（pure Go）
- Vim との連携: [goda.vim](https://github.com/Shougo/goda.vim)

## 導入

```vim
set runtimepath+=~/vim_markdown_viewer/deps/goda.vim
set runtimepath+=~/vim_markdown_viewer/mdview
filetype plugin on
```

Vim で `:MdviewBuild` を実行します（または `cd go && go build -o ../bin/mdview .`）。

詳しくは `:help mdview` を見てください。

## 構成

```
plugin/mdview.vim     コマンドと自動有効化
autoload/mdview.vim   仮想行・popup・fold の制御
go/                   goda プラグイン（ブロック抽出・描画・キャッシュ）
doc/mdview.txt        ヘルプ
testdata/             確認用の Markdown
```

## テスト

```sh
cd go && go test ./...
echo '{"method":"goda.plugins"}' | ./bin/mdview --transport=jsonl
```
