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
- ビューアのリンクを <CR>（か gx）で開く。`#見出し` はその見出しへ、ローカルの Markdown はその文書のビューアへ、
  URL や画像・PDF は OS のアプリで開く。<BS> で前の場所に戻る
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

mdview と goda.vim の 2 つを Vim のプラグインとして入れ、mdview の Go のプログラムをビルドします。
dal と dam は、ビルドのときに Go が取ってきます。

ビルドは `:MdviewBuild`（関数では `mdview#build()`）で行います。goda.vim の `goda#build()` を使い、
goda-cmp.vim などと同じく、バイナリはプラグインの外の `~/.cache/vim/mdview/mdview` に作ります
（`$XDG_CACHE_HOME` があれば `$XDG_CACHE_HOME/vim/mdview/mdview`。`g:mdview_bin` で変えられます）。
ビルドが終わるまで Vim は待ちます。初めてのビルドは、モジュールを取ってくるので時間がかかります。

Go 側は、`go/go.mod` に書いた版ではなく、入れてある goda.vim でビルドします（goda-pm.vim の
`g:goda#workspace` と同じしくみ。go.work はバイナリの隣に作ります）。goda.vim を更新したあとも、
`:MdviewBuild` するだけで、その goda.vim に合ったバイナリになります。`go.mod` の版でビルドしたいときは
`let g:goda#workspace = []` にします。

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

### vim-plug で入れる

```vim
Plug 'Shougo/goda.vim'
Plug 'lea-151107/mdview', { 'do': { -> mdview#build() } }
```

`:PlugInstall` と `:PlugUpdate` のあとにビルドします。

### goda-pm.vim・dpp.vim で入れる

```toml
[[plugins]]
repo = 'Shougo/goda.vim'

[[plugins]]
repo = 'lea-151107/mdview'
hook_post_update = 'call mdview#build()'
```

mdview は、自分のディレクトリにある `go/` をビルドします。ほかのプラグインとまとめる（merged）とき、
シンボリックリンクならそのままで動きます。Windows（ハードリンク）などでまとめた先から `go/` をたどれないときは、
`:MdviewBuild` が `merged = false` にするよう案内するので、その指示に従ってください。

### ほかの方法で入れる

goda.vim と mdview の 2 つを `'runtimepath'` に入れ、mdview を入れたあと（更新したあとも）に
`:MdviewBuild` を実行します。

```vim
set runtimepath+=/path/to/goda.vim
set runtimepath+=/path/to/mdview
```

### 更新したとき

mdview や goda.vim を更新したら、`:MdviewBuild` でビルドし直します。上の vim-plug・goda-pm.vim の設定では、
mdview を更新したときは自動で行います（vim-plug では、goda.vim だけを更新したときは行いません）。
Go のプログラムと Vim script の版が合わないときは、goda.vim が
「build the binary again」と表示するので、`:MdviewBuild` を実行してください。

以前の版は、バイナリを mdview の中の `bin/mdview` に作っていました。今は使わないので、消してかまいません。
vim-plug の `'do': 'cd go && go build ...'` や goda-pm.vim の `installerBuild` を設定していたら、上の書き方に替えてください。

詳しくは `:help mdview` を見てください。

## dal・dam と一緒に開発する

dal や dam を直しながら mdview で確かめるときは、3 つを同じディレクトリに clone し、
その親に `go.work` を作ります。ビルドとテストは clone した dal と dam を使います。

```sh
git clone https://github.com/lea-151107/dal
git clone https://github.com/lea-151107/dam
go work init ./mdview/go ./dal ./dam
```

`:MdviewBuild` もこの `go.work` でビルドします。ただし goda-pm.vim を使っていると、goda-pm.vim のプラグイン
（`g:goda#workspace`）でビルドするので、この `go.work` は使いません。そのときは dal と dam を goda-pm.vim の
`local` のプラグインとして入れます。

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
make check   # gofmt・go mod tidy の差分・go vet・staticcheck・Go のテスト・Vim script のテスト
             # Go のテストは、本物の Vim と goda.vim でビューアを開く試験（test/e2e.vim）も行う（-short で省く）
make build   # bin/mdview（開発用。Vim で使うには g:mdview_bin で指す）
echo '{"method":"goda.plugins"}' | ./bin/mdview --transport=jsonl
```

確認用の文書: `testdata/full.md`（書式・表・図・数式・画像の一覧）、`testdata/nested.md`（入れ子と文中の要素）

## ライセンス

MIT License です（[LICENSE](LICENSE)）。
