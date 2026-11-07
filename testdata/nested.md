# 入れ子と文中の要素の確認

古い行単位の抽出で見落とし・誤検出していたケースです。

## リストの中の mermaid（字下げ 4 桁）

- 手順

    ```mermaid
    graph LR
      A --> B
    ```

- 次の項目

## 引用の中の mermaid と数式

> ```mermaid
> graph TD
>   X --> Y
> ```
>
> $$
> \int_0^1 x\,dx = \frac{1}{2}
> $$

> $$a^2 + b^2 = c^2$$

## 描かないもの

インデントのコードブロック:

    $$x^2$$

HTML のコメント:

<!--
$$x$$
-->

pre:

<pre>
$$x$$
</pre>

## 画像

参照形式の画像:

![参照][grad]

[grad]: gradient.png

文中の画像 ![文中](gradient.png) は、行の下に描きます。

リンク付きの画像:

[![リンク付き](gradient.png)](https://example.com)

リストの中の画像:

1. 1 番目
2. ![リストの中](gradient.png)

同じ行に 2 つ:

![左](gradient.png) ![右](gradient.png)

## インライン数式

二次方程式 $ax^2 + bx + c = 0$ の解は $x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$ です。
$5 と $10 は数式になりません。`$code$` もそのままです。
