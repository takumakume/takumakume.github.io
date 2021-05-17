---
author: "Takuma Kume"
title: "kubectl実行時に任意のコマンドを実行して認証情報を更新できるpluginを実装した"
linktitle: "kubectl実行時に任意のコマンドを実行して認証情報を更新できるpluginを実装した"
date: 2021-05-17T20:38:52+09:00
draft: false
highlight: true
tags: ["cloudnative", "kubernetes", "kubectl-credentials-broker"]
---

[takumakume/kubectl-credentials-broker](https://github.com/takumakume/kubectl-credentials-broker) という kubectl plugin を作ったので、経緯やできることについて説明します。

## kubectl-credentials-broker とは

一言でいうと、 kubectl 実行時に任意のコマンドを実行して指定されたクライアント証明書やトークンのファイルを読み取って、kube-apiserverの認証情報として利用する kubectl の plugin です。

任意のコマンドは、kube-apiserverの認証に使うクライアント証明書やトークンが有効でない場合に、何らかの処理を実行して、それらを取得しファイルに出力することを想定しています。

この説明を図にすると以下のようになります。

![image](/img/2021-05-17/credentials-broker.jpeg)

## 開発経緯

オンプレミスでkubernetesクラスタを運用していて、kube-apiserverのAPIエンドポイントに対してPublicなインターネットから安全に繋ぎたいとします。

結論としては以下の図のような2要素認証を実現することが目的です。

![image](/img/2021-05-17/auth.jpeg)

`グリーン` で示した部分は、Githubのトークンによる認証・認可です。リクエストに付与されたGithubのトークンが有効であることを検証することで認証しています。更にトークンのユーザ名を使って kubernetes の RBAC を使って認可をする仕組みです。

この仕組みに加えて、固定IPアドレスによるアクセス制限をすることで多層防御となり実運用に耐えうるセキュリティレベルを担保することができそうです。
しかし、このモデルの場合はVPN等を活用して指定のIPアドレスからアクセスをする必要があり煩雑です。

私はこの問題を解決するために、IPアドレスベースの境界モデルをやめてPublicなインターネットに安全にkube-apiserverのエンドポイントを公開したいと考えました。

手段は無数にあるでしょうが、今回は以下の `ブルー` で示した仕組みを入れてみます。
HashiCorp VaultのPKIを認証局として、kube-apiserverの前段にmTLSを行うreverse proxyを配置する方法です。

この方法では、安全のためにクライアントに発行するクライアント証明書の有効期限を24hにしています。

ここで発生する課題として **kubectlを実行したが、証明書が切れていたので再発行しなければならない** ということがたびたび発生してしまうということです。
これは非常に面倒なので[takumakume/kubectl-credentials-broker](https://github.com/takumakume/kubectl-credentials-broker)の開発に至ります。

## 動作概要

`kubectl-credentials-broker` は [kubernetes client-go credential plugin](https://kubernetes.io/ja/docs/reference/access-authn-authz/authentication/#client-go%E3%82%AF%E3%83%AC%E3%83%87%E3%83%B3%E3%82%B7%E3%83%A3%E3%83%AB%E3%83%97%E3%83%A9%E3%82%B0%E3%82%A4%E3%83%B3) という仕組みを使っています。これは kubectl 実行時に外部コマンドを実行してユーザーの認証情報を取得する仕組みです。外部コマンドが以下のような形式のJSONを出力することで、kubectlが認証情報として利用します。

```json
{
  "kind": "ExecCredential",
  "apiVersion": "client.authentication.k8s.io/v1beta1",
  "spec": {},
  "status": {
    "token": "XXXXXXXX",
    "clientCertificateData": "-----BEGIN CERTIFICATE-----\n ...",
    "clientKeyData": "-----BEGIN RSA PRIVATE KEY-----\n ..."
  }
}
```

`kubectl-credentials-broker` は任意のコマンドを実行し、 `token` , `clientCertificateData` , `clientKeyData` に対応するファイルを出力した上で、それらのファイルを読み込んで、上記の形式のJSONを生成します。

全体イメージは冒頭の図を参照ください。

## 導入例

kubernetes client-go credential plugin の機能を使うためには、 kubeconfig の current-context の user に対して以下の設定をする必要があります。

```yaml
users:
- name: user1
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      args:
      - credentials-broker
      - --before-exec-command
      - /path/to/update.sh
      - --client-certificate-path
      - /path/to/server.cert
      - --client-key-path
      - /path/to/server.key
      - --token-path
      - /path/to/token
      command: kubectl
      env:
      - name: TOKEN
        value: XXXXXXXX
```

以下のコマンドを実行することで同じことができます。

```
$ kubectl credentials-broker kubeconfig set \
  --before-exec-command /path/to/update.sh \
  --client-certificate-path /path/to/server.cert \
  --client-key-path /path/to/server.key \
  --token-path /path/to/token \
  --env=TOKEN=XXXXXXXX
```

実行するとkubeconfigのDiffが表示されるので問題がなければ `yes` で書き換えます。 `-f` をつけることでスキップできます。

`/path/to/update.sh` の一例を書いてみます。

```sh
#!/bin/bash

openssl x509 -checkend 1 -noout -in /path/to/server.cert
if [ $? -ne 0 ]; then
    # Generate client certificate file if expired ...
    #  /path/to/server.cert (Can contain CA certificate)
    #  /path/to/server.key
fi

if [ ! -e "/path/to/token" ]; then
    # Generate token if not exists ...
    #  /path/to/token
fi
```

この例では、証明書が無効な時と、トークンファイルが存在しないときに何かしらの処理をするシェルスクリプトです。
なお、 `--before-exec-command` で指定するコマンドは、kubectlが実行されるたびに実行されるため、認証情報を更新する必要がない場合は軽量に保つほうが良いです。

以上がツールの説明です。

このツールによって、認証情報の有効期限が切れていた場合に、kubectlを実行するだけでシームレスに更新処理を実行することができます。

kubectl-credentials-broker の利点は `任意のコマンド` が実行できるため、認証情報を更新する作業がコードで記述できる場合であればどんな形式でも対応できることです。

