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

## 必要なもの

- Vim 9.2 以降（`+textprop`）
- 図・数式・画像を描くには、さらに `+image`・`+image_popup`・`+popupwin` と、sixel か kitty の画像を表示できる端末。
  無いときはテキストだけで表示します（`g:mdview_images`）
- [goda.vim](https://github.com/Shougo/goda.vim)。Go のプログラムと Vim をつなぐ Vim のプラグインです
- ビルドに Go 1.26 以降と、ネットワーク（初めてのビルドで dal・dam などのモジュールを取ってくるため）。
  実行には Go は要りません

## 導入

mdview と goda.vim の 2 つを Vim のプラグインとして入れ、mdview の Go のプログラム（`bin/mdview`）を
ビルドします。dal と dam は、ビルドのときに Go が取ってきます。

### Vim のパッケージで入れる

```sh
mkdir -p ~/.vim/pack/plugins/start
cd ~/.vim/pack/plugins/start
git clone https://github.com/lea-151107/mdview
git clone https://github.com/Shougo/goda.vim
```

Vim を起動して、次を実行します。

```vim
:MdviewBuild
:helptags ALL
```

`:MdviewBuild` は `mdview/go` で `go build` し、`mdview/bin/mdview` を作ります。
シェルから `cd mdview/go && go build -o ../bin/mdview .` を実行しても同じです。

### vim-plug で入れる

```vim
Plug 'Shougo/goda.vim'
Plug 'lea-151107/mdview', { 'do': 'cd go && go build -o ../bin/mdview .' }
```

`:PlugInstall` と `:PlugUpdate` のあとに、mdview のディレクトリでビルドします。

### goda-pm.vim・dpp.vim で入れる

```toml
[[plugins]]
repo = 'Shougo/goda.vim'

[[plugins]]
repo = 'lea-151107/mdview'
merged = false
extAttrs.installerBuild = 'cd go && go build -o ../bin/mdview .'
```

mdview は自分のディレクトリの中でビルドし、`bin/mdview` をそこから探します。
ほかのプラグインとまとめる（merged）と、ビルドする場所と探す場所がずれるので、`merged = false` にします。

### ほかの方法で入れる

goda.vim と mdview の 2 つを `'runtimepath'` に入れ、mdview を入れたあと（更新したあとも）に
`:MdviewBuild` を実行します。

```vim
set runtimepath+=/path/to/goda.vim
set runtimepath+=/path/to/mdview
```

### 更新したとき

mdview を更新したら、ビルドし直します（上の vim-plug・goda-pm.vim の設定では自動で行います）。
Go のプログラムと Vim script の版が合わないときは、goda.vim が「build the binary again」と表示するので、
`:MdviewBuild` を実行してください。

詳しくは `:help mdview` を見てください。

## dal・dam と一緒に開発する

dal や dam を直しながら mdview で確かめるときは、3 つを同じディレクトリに clone し、
その親に `go.work` を作ります。ビルドとテストは clone した dal と dam を使います。

```sh
git clone https://github.com/lea-151107/dal
git clone https://github.com/lea-151107/dam
go work init ./mdview/go ./dal ./dam
```

dal や dam を公開し直したら、`cd go && go get github.com/lea-151107/dal@vX.Y.Z` で
`go/go.mod` のバージョンを上げます。

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
