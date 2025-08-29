import express, { Request, Response } from 'express';
import zstandard from '@zstd/zstd';
import { Pool, PoolClient } from 'pg';
import amqp from 'amqplib';
import { Buffer } from 'buffer';

// --- ロギング設定 ---
// シンプルなコンソールロガーを使用
const logger = {
    info: (message: string) => console.log(`[INFO] ${new Date().toISOString()} - ${message}`),
    error: (message: string, error?: any) => console.error(`[ERROR] ${new Date().toISOString()} - ${message}`, error || ''),
};

// --- 環境変数からの設定読み込み ---
const config = {
    db: {
        host: process.env.DB_HOST || 'localhost',
        port: parseInt(process.env.DB_PORT || '5432', 10),
        database: process.env.DB_NAME || 'eeg_db',
        user: process.env.DB_USER || 'user',
        password: process.env.DB_PASSWORD || 'password',
    },
    mq: {
        hostname: process.env.MQ_HOST || 'localhost',
        port: parseInt(process.env.MQ_PORT || '5672', 10),
        username: process.env.MQ_USER || 'guest',
        password: process.env.MQ_PASSWORD || 'guest',
        exchange: 'eeg_events',
        routingKey: 'eeg.raw.new',
    }
};

// --- 定数 ---
const STRUCT_POINT_SIZE = 68; // 8*2 + 12*4 + 4 = 68 bytes
const NUM_EEG_CHANNELS = 8;
const CHANNEL_NAMES = ['Fp1', 'Fp2', 'F7', 'F8', 'T7', 'T8', 'P7', 'P8'];

// --- Expressアプリケーションの初期化 ---
const app = express();
app.use(express.json({ limit: '10mb' })); // 受信するJSONのサイズ上限を上げる

// --- データベース接続プールの設定 ---
const dbPool = new Pool(config.db);
dbPool.on('error', (err) => {
    logger.error('PostgreSQL Pool Error:', err);
});

// --- RabbitMQ 接続とメッセージ発行 ---
async function publishToMq(messageBody: object): Promise<void> {
    let connection: amqp.Connection | null = null;
    try {
        connection = await amqp.connect(config.mq);
        const channel = await connection.createChannel();

        await channel.assertExchange(config.mq.exchange, 'topic', { durable: true });

        channel.publish(
            config.mq.exchange,
            config.mq.routingKey,
            Buffer.from(JSON.stringify(messageBody)),
            {
                contentType: 'application/json',
                persistent: true, // メッセージを永続化
            }
        );
        logger.info(`メッセージを発行しました: ${JSON.stringify(messageBody)}`);

        await channel.close();
    } catch (error) {
        logger.error('メッセージの発行に失敗しました:', error);
    } finally {
        if (connection) {
            await connection.close();
        }
    }
}

// --- メインのAPIエンドポイント ---
app.post('/upload/eeg', async (req: Request, res: Response) => {
    const { user_id, device_id, session_id, sampling_rate_hz, payload_zstd } = req.body;

    if (!user_id || !device_id || !session_id || !sampling_rate_hz || !payload_zstd) {
        return res.status(400).json({ error: 'Missing required fields' });
    }

    let dbClient: PoolClient | null = null;

    try {
        // --- データのデコードと解凍 ---
        const compressedData = Buffer.from(payload_zstd, 'base64');
        const rawBytes = zstandard.decompress(compressedData);
        const rawBuffer = Buffer.from(rawBytes);

        // --- データのパースとDB保存用レコードの準備 ---
        const recordsToInsert: any[][] = [];
        for (let offset = 0; offset < rawBuffer.length; offset += STRUCT_POINT_SIZE) {
            if (offset + STRUCT_POINT_SIZE > rawBuffer.length) continue;

            const eegValues: number[] = [];
            // EEG (8 * uint16_t)
            for (let i = 0; i < NUM_EEG_CHANNELS; i++) {
                eegValues.push(rawBuffer.readUInt16LE(offset + i * 2));
            }
            // IMU (12 * float) - 今回はスキップ
            // Timestamp (1 * uint32_t)
            const device_timestamp_us = rawBuffer.readUInt32LE(offset + 16 + 48);
            const server_time = new Date();

            for (let i = 0; i < NUM_EEG_CHANNELS; i++) {
                recordsToInsert.push([
                    server_time, session_id, user_id, device_id,
                    CHANNEL_NAMES[i], eegValues[i], device_timestamp_us
                ]);
            }
        }

        if (recordsToInsert.length === 0) {
            return res.status(200).json({ status: "ok", message: "No data to insert." });
        }

        // --- データベースへのバルクインサート ---
        // pgライブラリには直接のバルクインサートヘルパーがないため、
        // 複数のVALUES句を持つ1つのクエリを構築する
        const valuesPlaceholder = recordsToInsert.map((_, i) =>
            `($${i * 7 + 1}, $${i * 7 + 2}, $${i * 7 + 3}, $${i * 7 + 4}, $${i * 7 + 5}, $${i * 7 + 6}, $${i * 7 + 7})`
        ).join(',');

        const sql = `
            INSERT INTO bio_signal_raw 
            (time, session_id, user_id, device_id, channel_name, value, device_timestamp_us) 
            VALUES ${valuesPlaceholder}
        `;
        const flatValues = recordsToInsert.flat();
        
        dbClient = await dbPool.connect();
        await dbClient.query(sql, flatValues);
        logger.info(`${recordsToInsert.length}件のレコードをDBに保存しました。 (session: ${session_id})`);


        // --- SignalLabへの通知 (メッセージキュー) ---
        const notificationMessage = {
            type: "NEW_EEG_BLOCK",
            session_id,
            user_id,
            num_records: recordsToInsert.length,
            received_at: new Date().toISOString()
        };
        await publishToMq(notificationMessage);

        return res.status(201).json({ status: "ok", inserted_records: recordsToInsert.length });

    } catch (error) {
        logger.error('予期せぬエラー:', error);
        return res.status(500).json({ error: 'An internal server error occurred' });
    } finally {
        if (dbClient) {
            dbClient.release(); // プールにコネクションを返却
        }
    }
});

// --- サーバーの起動 ---
const PORT = process.env.PORT || 6000;
app.listen(PORT, () => {
    logger.info(`Server is running on http://0.0.0.0:${PORT}`);
    // zstdライブラリの初期化 (非同期)
    zstandard.init();
});
