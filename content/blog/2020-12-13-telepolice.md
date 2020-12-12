---
author: "Takuma Kume"
title: "telepresenceを用いた開発環境における現状の課題"
linktitle: "telepolice"
date: 2020-12-12T00:00:00+09:00
draft: false
highlight: true
tags: ["kubernetes", "telepresence", "telepolice"]
---

---
この記事は [GMO ペパボエンジニア Advent Calendar 2020](https://adventar.org/calendars/5420) の 13日目 の記事です。

昨日は @mrtc0 さんの [「Kubernetes のセキュリティを学べる kubectf を作った](https://blog.ssrf.in/post/kubectf/)」 でした。
私も社内でkubectfをやっていて、mrtc0さん直々に教えてもらっています。ほんとうに福利厚生です。

---

## 目次

- はじめに
- telepresence について
- 開発環境の説明
- 生じた課題と解決方法
- 新たに発生した課題
- 今後について

## はじめに

kumesec こと @takumakume です。
GMOペパボのホスティング事業部でSREをしています。

現在の仕事はVMベースのインフラ上で運用しているWebアプリケーションを、kubernetesをはじめとしたツールの導入によりクラウドネィティブにしていくことです。
最近は kubernetes + OpenStack な環境でLBaaSを動かすためにあれこれしています。

本エントリでは [telepresenceio/telepresence](https://github.com/telepresenceio/telepresence) を用いた開発環境における現状の課題を説明したいと思います。

## telepresence について

本エントリに興味を持った人は、おそらくtelepresenceを既に使っている方が多いと思いますし、telepresenceの説明については既に多くの資料があるためここでは割愛します。

弊社のエンジニアが書いている以下の資料が参考になります。

[telepresence で始める k8s 時代のローカル開発](https://speakerdeck.com/shiro16/telepresence-deshi-meru-k8s-shi-dai-falserokarukai-fa)

## telepresence-0.105 までの動作について

課題を説明前に、前提知識として `telepresence-0.105` の動きを説明します。

以下のような Deployment が存在していて、 `App` の開発を Client で行いたいとします。

![image](/img/2020-12-13/1.png)

その場合に、以下のようなコマンドを実行します。

```
telepresence --swap-deployment {DEPLOYMENT_NAME} \
  --method container \
  --from-pod 8001 \
  --docker-run --rm -v `pwd`:/src myapp:0.0.1
```

そうすると、環境は以下のように変化します。

![image](/img/2020-12-13/2.png)

telepresence を実行すると kubernetes 環境に proxy の役割を担う Deployment が実行されます。
その proxy が受けるリクエストは手元で実行される `App` に転送されます。
手元 `App` はローカルのソースコードをマウントしているため、手元のエディタからの変更がアプリケーションに反映するという仕組みです。

次に、手元で実行中のtelepresenceを `Ctl+C` などで SIGINT を telepresence のプロセスに送信して終了することでクリーンナップ処理が実行されます。

![image](/img/2020-12-13/3.png)

上記のように、 proxy の Deployment が削除され、元の Deployment の Replica 数をリカバリし環境を元通りにします。


## 生じた課題と解決方法

[telepresenceio/telepresence/issues/260](https://github.com/telepresenceio/telepresence/issues/260) この課題が発生しました。

先程説明したように、シグナルを送信して正常終了した場合はクリーンナップ処理が行われて環境が元に戻ります。
しかし、telepresenceを使って開発している途中にパソコンを閉じてネットワークから切り離されたり、ターミナルを閉じてしまいシェル毎終了したりすることで、クリーンナップ処理が走らないパターンが発生します。

その場合は、以下のように kubernetes 上の proxy と手元とのコネクションがダウンした状態になります。

![image](/img/2020-12-13/4.png)

このままでは、 `App` は存在しない状態になってしまうので、他の開発をしたいときに `App` が機能しない状態となってしまうため手動でクリーンナップ処理相当のリカバリをする必要がありました。

そこで、私は以下のソフトウェアを実装して定期的にこのような状態になった Deployment を検知して、リカバリ処理相当のことを自動的に行うようにしました。

[takumakume/telepolice](https://github.com/takumakume/telepolice)

このソフトウェアは具体的に以下の動きをします。

- `telepresence` ラベルが付与されたPodを探索 (telepresenceが生成するproxyの役割を持ったPod)
- それらのPodに対して `kubectl exec` 相当を実行し、proxyプロセスが応答するか確認 ( `nc localhost 9055` で応答するか)
- 数回失敗したPodは不正終了をしたとみなしてリカバリを実行
  - telepresence proxy Pod の `OwnerReferences` を使って、Deploymentを特定
  - **telepresence proxy Deployment の `last-applied-configuration` Annotation 内に元のDeployment名が入っているので、その情報を使って元のDeplpymentのreplica数を元に戻す**
  - telepresence proxy Deployment を Delete

この動作を定期的に実行することで、不正終了した telepresence のリソースをリカバリしていました。

## 新たに発生した課題

`telepresence-0.106` から挙動が変わり、開発した telepolice が機能しなくなりました。
以下の動作ができなくなったのが原因です。

> telepresence proxy Deployment の `last-applied-configuration` Annotation 内に元のDeployment名が入っているので、その情報を使って元のDeplpymentのreplica数を元に戻す

理由は、以下の変更が telepresence に加わったためです。

[telepresenceio/telepresence/pull/1404 - Proxy as a Pod](https://github.com/telepresenceio/telepresence/pull/1404)

これまで、 telepresence の proxy は Deployment として作られており、元の Deployment の `last-applied-configuration` をコピーしてくれていました。

しかし、これからは Deployment ではなく Pod として作られることになり、 `last-applied-configuration` もなくなり、元の Deployment を辿るための情報がなくなってしまいました。

Deployment から Pod に変更された理由を追うと、以下のような点がありました。

- シンプルである
- Deployment よりも Pod の方が高速
- 将来的に Deployment 以外のコントローラーをサポートできる

理由については非常に納得できます。

### ワークアラウンドについて

新たに課題が発生しましたが、現時点では telepresence 実行時の環境変数に `TELEPRESENCE_USE_DEPLOYMENT` を付与することで、従来通りのDeploymentの挙動に戻す事ができます。

## 今後の対応

ひとまずは telepresence の仕様変更に追従していきたいと思っています。
ただし、今のやり方では元の Deployment を機械的に判断する方法がありません。
そのため、 telepresence proxy Pod を生成するときに Annotation 等に必要な情報を突っ込んでおくといったことをする必要がありそうです。
この場合は telepresence 自体に機能を追加することになるかもしれません。よりよい方法がないか考えたいと思います。

## 最後に

telepolice というソフトウェアを使って telepresence の不正終了のリカバリを自動化しています。
telepresence を使っていて、同じ問題に遭遇した方は他にどんな手段でリカバリをしているのか気になりますので、別の案をお持ちの方がいらっしゃれば是非コメントを頂きたいと思います！

---

明日の [Advent Calendar](https://adventar.org/calendars/5420) は kitkatayama さんです！
