# SentimentFlow API 文档（v1）

## 1. 基本信息

- **Base URL**：`/api`
- **请求格式**：`application/json`（SSE 接口除外）
- **响应格式**：`application/json`
- **字符集**：UTF-8
- **时间格式**：ISO 8601（示例：`2026-05-15T22:16:45+08:00`）

---

## 2. 通用约定

### 2.1 成功响应（建议）

```json
{
  "code": 0,
  "message": "ok",
  "data": {}
}
```

### 2.2 失败响应（建议）

```json
{
  "code": 40001,
  "message": "validation error",
  "error": {
    "type": "VALIDATION_ERROR",
    "details": [
      {
        "field": "text",
        "reason": "text is required"
      }
    ]
  }
}
```

### 2.3 常见 HTTP 状态码

| 状态码 | 含义 |
| --- | --- |
| 200 | 请求成功 |
| 201 | 创建成功 |
| 400 | 参数错误 |
| 401 | 未认证 |
| 403 | 无权限 |
| 404 | 资源不存在 |
| 409 | 状态冲突 |
| 422 | 语义错误 |
| 500 | 服务内部错误 |

---

## 3. 接口总览

| 模块 | 方法 | 端点 | 说明 |
| --- | --- | --- | --- |
| Auth | POST | `/api/auth/login` | 登录 stub |
| Predict | POST | `/api/predict/` | 情感预测（含完整请求/响应 Schema） |
| Training | POST | `/api/training/start` | 启动训练任务 |
| Training | GET | `/api/training/status/{job_id}` | 查询训练状态（含进度详情） |
| Training | GET | `/api/training/stream/{job_id}` | SSE 实时推送训练日志/进度 |
| Training | GET | `/api/training/jobs` | 列出所有训练任务 |
| Training | POST | `/api/training/cancel/{job_id}` | 取消训练 |
| Models | GET | `/api/models/` | 列出所有模型 |
| Models | GET | `/api/models/active` | 获取当前激活模型 |
| Models | PUT | `/api/models/active` | 设置激活模型 |
| Models | DELETE | `/api/models/{model_id}` | 删除模型 |
| Stats | GET | `/api/stats/overview` | 统计概览 stub |
| Admin | GET | `/api/admin/users` | 管理员 stub |

---

## 4. Auth 模块

### 4.1 POST `/api/auth/login`

登录（stub）。

#### 请求体

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| username | string | 是 | 用户名 |
| password | string | 是 | 密码 |

#### 请求示例

```json
{
  "username": "admin",
  "password": "123456"
}
```

#### 响应示例（stub）

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "access_token": "stub-token",
    "token_type": "Bearer",
    "expires_in": 3600,
    "user": {
      "id": "u_001",
      "username": "admin",
      "role": "admin"
    }
  }
}
```

---

## 5. Predict 模块

### 5.1 POST `/api/predict/`

输入文本并返回情感预测结果。

#### 请求体 Schema（完整）

| 字段 | 类型 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| text | string | 是 | - | 待预测文本 |
| model_id | string | 否 | 当前激活模型 | 指定模型 ID |
| return_probabilities | boolean | 否 | true | 是否返回各类别概率 |
| include_metadata | boolean | 否 | false | 是否返回输入元信息 |
| top_k | integer | 否 | 3 | 返回前 K 个标签（1~10） |

#### 请求示例

```json
{
  "text": "这个产品体验很好，物流也很快。",
  "model_id": "model_bert_zh_v3",
  "return_probabilities": true,
  "include_metadata": true,
  "top_k": 3
}
```

#### 响应体 Schema（完整）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| request_id | string | 请求追踪 ID |
| model.id | string | 实际使用模型 ID |
| model.name | string | 模型名称 |
| model.version | string | 模型版本 |
| input.text | string | 原始输入文本 |
| input.language | string | 语言，如 `zh` |
| input.length | integer | 文本长度 |
| prediction.label | string | 主预测标签（如 `positive`） |
| prediction.score | number | 主标签分值（0~1） |
| prediction.confidence | number | 置信度（0~1） |
| prediction.probabilities | object | 各标签概率 |
| prediction.top_k | array | Top-K 标签及概率 |
| timing_ms | integer | 推理耗时（毫秒） |
| created_at | string | 响应生成时间 |

#### 响应示例

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "request_id": "req_9f2a7f",
    "model": {
      "id": "model_bert_zh_v3",
      "name": "BERT Chinese Sentiment",
      "version": "3.2.1"
    },
    "input": {
      "text": "这个产品体验很好，物流也很快。",
      "language": "zh",
      "length": 16
    },
    "prediction": {
      "label": "positive",
      "score": 0.9731,
      "confidence": 0.962,
      "probabilities": {
        "negative": 0.0093,
        "neutral": 0.0176,
        "positive": 0.9731
      },
      "top_k": [
        {
          "label": "positive",
          "score": 0.9731
        },
        {
          "label": "neutral",
          "score": 0.0176
        },
        {
          "label": "negative",
          "score": 0.0093
        }
      ]
    },
    "timing_ms": 23,
    "created_at": "2026-05-15T22:16:45+08:00"
  }
}
```

---

## 6. Training 模块

### 6.1 POST `/api/training/start`

启动训练任务（异步）。

#### 请求体

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| dataset_path | string | 是 | 数据集路径或标识 |
| model_type | string | 是 | 模型类型（如 `bert` / `lstm`） |
| hyperparams | object | 否 | 训练超参数（如 epochs、batch_size、learning_rate） |
| notes | string | 否 | 任务备注 |

#### 请求示例

```json
{
  "dataset_path": "datasets/sentiment/train_v5.csv",
  "model_type": "bert",
  "hyperparams": {
    "epochs": 5,
    "batch_size": 32,
    "learning_rate": 2e-5
  },
  "notes": "nightly training"
}
```

#### 响应示例

```json
{
  "code": 0,
  "message": "training job created",
  "data": {
    "job_id": "job_20260515_001",
    "status": "queued",
    "created_at": "2026-05-15T22:16:45+08:00"
  }
}
```

### 6.2 GET `/api/training/status/{job_id}`

查询训练任务状态与进度详情。

#### 路径参数

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| job_id | string | 训练任务 ID |

#### 响应示例

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "job_id": "job_20260515_001",
    "status": "running",
    "progress": {
      "percent": 46.5,
      "epoch": 3,
      "total_epochs": 5,
      "step": 930,
      "total_steps": 2000,
      "eta_seconds": 842
    },
    "metrics": {
      "train_loss": 0.2134,
      "val_loss": 0.2481,
      "val_accuracy": 0.923
    },
    "started_at": "2026-05-15T22:20:00+08:00",
    "updated_at": "2026-05-15T22:28:10+08:00"
  }
}
```

### 6.3 GET `/api/training/stream/{job_id}`

SSE 实时推送训练日志与进度。

#### 响应头

- `Content-Type: text/event-stream`
- `Cache-Control: no-cache`
- `Connection: keep-alive`

#### 事件类型（建议）

- `training.started`
- `training.progress`
- `training.log`
- `training.completed`
- `training.failed`
- `heartbeat`

#### SSE 示例

```text
event: training.started
data: {"job_id":"job_20260515_001","started_at":"2026-05-15T22:20:00+08:00"}

event: training.progress
data: {"job_id":"job_20260515_001","percent":12.3,"epoch":1,"step":246,"total_steps":2000}

event: training.log
data: {"level":"INFO","message":"epoch 1 step 300 loss=0.4831","time":"2026-05-15T22:21:10+08:00"}

event: training.completed
data: {"job_id":"job_20260515_001","model_id":"model_bert_zh_v4","best_val_accuracy":0.931}
```

### 6.4 GET `/api/training/jobs`

列出所有训练任务。

#### Query 参数（可选）

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| status | string | all | 可选：`queued/running/succeeded/failed/cancelled` |
| page | integer | 1 | 页码 |
| page_size | integer | 20 | 每页条数 |

#### 响应示例

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "items": [
      {
        "job_id": "job_20260515_001",
        "status": "running",
        "model_type": "bert",
        "created_at": "2026-05-15T22:16:45+08:00"
      }
    ],
    "page": 1,
    "page_size": 20,
    "total": 1
  }
}
```

### 6.5 POST `/api/training/cancel/{job_id}`

取消训练任务。

#### 路径参数

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| job_id | string | 训练任务 ID |

#### 响应示例

```json
{
  "code": 0,
  "message": "cancel requested",
  "data": {
    "job_id": "job_20260515_001",
    "status": "cancelling"
  }
}
```

---

## 7. Models 模块

### 7.1 GET `/api/models/`

列出所有模型。

#### 响应示例

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "items": [
      {
        "model_id": "model_bert_zh_v3",
        "name": "BERT Chinese Sentiment",
        "version": "3.2.1",
        "type": "bert",
        "is_active": true,
        "created_at": "2026-05-10T12:00:00+08:00"
      }
    ],
    "total": 1
  }
}
```

### 7.2 GET `/api/models/active`

获取当前激活模型。

#### 响应示例

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "model_id": "model_bert_zh_v3",
    "name": "BERT Chinese Sentiment",
    "version": "3.2.1",
    "activated_at": "2026-05-14T09:00:00+08:00"
  }
}
```

### 7.3 PUT `/api/models/active`

设置激活模型。

#### 请求体

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| model_id | string | 是 | 要激活的模型 ID |

#### 请求示例

```json
{
  "model_id": "model_lstm_zh_v2"
}
```

#### 响应示例

```json
{
  "code": 0,
  "message": "active model updated",
  "data": {
    "model_id": "model_lstm_zh_v2",
    "activated_at": "2026-05-15T22:30:00+08:00"
  }
}
```

### 7.4 DELETE `/api/models/{model_id}`

删除模型。

#### 路径参数

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| model_id | string | 模型 ID |

#### 响应示例

```json
{
  "code": 0,
  "message": "model deleted",
  "data": {
    "model_id": "model_old_001"
  }
}
```

---

## 8. Stats 模块

### 8.1 GET `/api/stats/overview`

统计概览（stub）。

#### 响应示例（stub）

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "total_predictions": 0,
    "total_training_jobs": 0,
    "active_model": null
  }
}
```

---

## 9. Admin 模块

### 9.1 GET `/api/admin/users`

管理员用户列表（stub）。

#### 响应示例（stub）

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "items": [
      {
        "id": "u_001",
        "username": "admin",
        "role": "admin"
      }
    ],
    "total": 1
  }
}
```

---

## 10. 错误码建议（可选）

| code | type | 说明 |
| --- | --- | --- |
| 40001 | VALIDATION_ERROR | 参数校验失败 |
| 40100 | UNAUTHORIZED | 未登录或 token 无效 |
| 40300 | FORBIDDEN | 权限不足 |
| 40400 | NOT_FOUND | 资源不存在 |
| 40900 | CONFLICT | 状态冲突 |
| 50000 | INTERNAL_ERROR | 服务内部错误 |

