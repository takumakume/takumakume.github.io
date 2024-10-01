---
author: "Takuma Kume"
title: "KubernetesにおけるSBOMを利用した脆弱性管理"
linktitle: "KubernetesにおけるSBOMを利用した脆弱性管理"
date: 2023-09-14T00:00:00+09:00
draft: false
highlight: true
tags: ["cloudnative", "security"]
---

[Pepabo Tech Conference #21 夏のSREまつり](https://pepabo.connpass.com/event/289574/) で 「KubernetesにおけるSBOMを利用した脆弱性管理」というタイトルで登壇しました。

GMOペパボでは、複数のWebサービスを複数のオンプレミスのKubernetes上で運用しています。
エンジニアは各ソフトウェアの脆弱性を管理し対応していく必要があります。

脆弱性管理において、以下の課題がありました。

- Kubernetes上で実行されている全てのコンテナイメージの脆弱性を網羅的に管理できていない
- 脆弱性の量が多すぎて全て対応するのが困難である

これらの課題に対して Trivy Operator や Dependency Track などを用いて対応してきたので、事例を紹介しました。

<script defer class="speakerdeck-embed" data-id="5c231c1eb7d44b6f96d18a50bf282671" data-ratio="1.7772511848341233" src="//speakerdeck.com/assets/embed.js"></script>
