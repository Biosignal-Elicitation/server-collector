EEG Collector Service (TypeScript Version)
これは、モバイルアプリケーションからリアルタイムで送信される脳波(EEG)データを受信、永続化し、後続の解析サービスへ通知するためのマイクロサービスです。Python版の機能をTypeScriptで再実装したものです。

アーキテクチャ

Webフレームワーク: Express.js

データベースクライアント: pg

メッセージキュークライアント: amqplib

解凍ライブラリ: @zstd/zstd

実行環境: Node.js

セットアップ
1. Node.js のインストール
お使いの環境にNode.js (バージョン18.x以上を推奨) をインストールしてください。

2. 依存ライブラリのインストール
プロジェクトのルートディレクトリで、package.json をもとに依存ライブラリをインストールします。

npm install

3. 環境変数の設定
Python版と同様に、データベースとRabbitMQへの接続情報を環境変数で設定します。

# PostgreSQL データベース設定
export DB_HOST=your_db_host
export DB_PORT=5432
export DB_NAME=eeg_db
export DB_USER=your_db_user
export DB_PASSWORD=your_db_password

# RabbitMQ 設定
export MQ_HOST=your_rabbitmq_host
export MQ_PORT=5672
export MQ_USER=guest
export MQ_PASSWORD=guest

4. TypeScriptのコンパイル
TypeScriptコードを、Node.jsが実行できるJavaScriptコードに変換（コンパイル）します。

npm run build

これにより、dist ディレクトリに collector_service.js が生成されます。

実行
開発用 (ホットリロード対応)
コードの変更を自動で検知してサーバーを再起動させたい場合は、開発モードで実行します。

npm run dev

本番用
コンパイル済みのJavaScriptファイルを実行します。

npm start

サーバーが http://0.0.0.0:6000 で起動します。
本番環境では、pm2 などのプロセス管理ツールを使ってアプリケーションをデーモン化し、安定稼働させることが一般的です。