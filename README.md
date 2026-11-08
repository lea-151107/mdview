# mdview

Vim の画像表示機能（`+image` の popup image）を使い、mermaid・ディスプレイ数式・画像を
描いた状態で Markdown を読めるビューアです。`:Mdview` で右に（`:Mdview here` で同じウィンドウに）
開きます。Markdown のファイル自体は普段どおりのエディタで開きます。

- 引用・リストの中のブロック、参照形式やリンク付きの画像、HTML の `<img>`、文中の画像、表のセルの中の画像も描く（goldmark で解析）
- インライン数式 `$…$` を `x²` のような 1 行のテキストにする
- 表を罫線で囲み、列を揃えて描く。セルの書式はハイライトで表し、幅に収まらないときはセルの中で折り返す
- コードブロックを枠と言語名で囲み、Vim の構文ファイルがある言語は設定なしで色を付ける
- 水平線（`---`・`***`・`___`）をビューアの幅の線にする
- 段落とリストの文は書式の記号を消してハイライトで表し、行をつなげてビューアの幅で折り返す
- 引用の `>` を縦線にし、GitHub のアラート（`> [!NOTE]` など）を種類ごとの色と見出しで描く
- 編集中も描き直す。時間のかかる図は後から出し、ほかのブロックを先に表示する
- BMP・SVG（rsvg-convert）・http(s) の画像（`g:mdview_remote`）
- 画像を表示できない端末（sixel・kitty に対応していない端末）や `+image` の無い Vim では、
  図・数式・画像をソースのまま出し、表などのテキストの表示だけで読める（`g:mdview_images`）

- mermaid: [dam](https://github.com/lea-151107/dam)（pure Go）
- 数式: [dal](https://github.com/lea-151107/dal)（pure Go）
- Vim との連携: [goda.vim](https://github.com/Shougo/goda.vim)

## 導入

mdview の Go 側は、dal と dam を `go/go.mod` の replace で隣のディレクトリから使います。
3 つを同じディレクトリに clone してください。

```sh
git clone https://github.com/lea-151107/mdview
git clone https://github.com/lea-151107/dal
git clone https://github.com/lea-151107/dam
git clone https://github.com/Shougo/goda.vim
```

```vim
set runtimepath+=/path/to/goda.vim
set runtimepath+=/path/to/mdview
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

確認用の文書: `testdata/full.md`（書式・表・図・数式・画像の一覧）、`testdata/nested.md`（入れ子と文中の要素）

## ライセンス

MIT License です（[LICENSE](LICENSE)）。
