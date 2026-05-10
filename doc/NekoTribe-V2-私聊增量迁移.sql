-- NekoTribe V2 direct messages incremental migration
-- Apply as NEKO_APP before enabling /api/v2/chat/direct-conversations.

CREATE SEQUENCE seq_direct_conversation_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_direct_message_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE n_direct_conversations (
    conversation_id      NUMBER(19)      PRIMARY KEY,
    user_low_id          NUMBER(19)      NOT NULL,
    user_high_id         NUMBER(19)      NOT NULL,
    created_by           NUMBER(19)      NOT NULL,
    last_message_id      NUMBER(19),
    last_message_at      TIMESTAMP,
    message_count        NUMBER(10)      DEFAULT 0 NOT NULL,
    is_deleted           NUMBER(1)       DEFAULT 0 NOT NULL,
    created_at           TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at           TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_direct_conv_low_user FOREIGN KEY (user_low_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_conv_high_user FOREIGN KEY (user_high_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_conv_creator FOREIGN KEY (created_by)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_direct_conversation_pair UNIQUE (user_low_id, user_high_id),
    CONSTRAINT chk_direct_conversation_pair CHECK (user_low_id < user_high_id),
    CONSTRAINT chk_direct_conversation_flags CHECK (is_deleted IN (0, 1)),
    CONSTRAINT chk_direct_conversation_counts CHECK (message_count >= 0)
) TABLESPACE neko_data;

COMMENT ON TABLE n_direct_conversations IS '私聊会话表';
COMMENT ON COLUMN n_direct_conversations.conversation_id IS '会话ID';
COMMENT ON COLUMN n_direct_conversations.user_low_id IS '较小用户ID';
COMMENT ON COLUMN n_direct_conversations.user_high_id IS '较大用户ID';
COMMENT ON COLUMN n_direct_conversations.created_by IS '创建人用户ID';
COMMENT ON COLUMN n_direct_conversations.last_message_id IS '最后消息ID';
COMMENT ON COLUMN n_direct_conversations.last_message_at IS '最后消息时间';
COMMENT ON COLUMN n_direct_conversations.message_count IS '消息数量';
COMMENT ON COLUMN n_direct_conversations.is_deleted IS '是否删除';

CREATE TABLE n_direct_messages (
    message_id           NUMBER(19)      PRIMARY KEY,
    conversation_id      NUMBER(19)      NOT NULL,
    sender_id            NUMBER(19)      NOT NULL,
    content              VARCHAR2(4000)  NOT NULL,
    is_deleted           NUMBER(1)       DEFAULT 0 NOT NULL,
    deleted_by           NUMBER(19),
    created_at           TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at           TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    edited_at            TIMESTAMP,
    deleted_at           TIMESTAMP,
    CONSTRAINT fk_direct_messages_conversation FOREIGN KEY (conversation_id)
        REFERENCES n_direct_conversations(conversation_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_messages_sender FOREIGN KEY (sender_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_messages_deleter FOREIGN KEY (deleted_by)
        REFERENCES n_users(user_id) ON DELETE SET NULL,
    CONSTRAINT chk_direct_message_flags CHECK (is_deleted IN (0, 1))
) TABLESPACE neko_data;

COMMENT ON TABLE n_direct_messages IS '私聊消息表';
COMMENT ON COLUMN n_direct_messages.message_id IS '消息ID';
COMMENT ON COLUMN n_direct_messages.conversation_id IS '会话ID';
COMMENT ON COLUMN n_direct_messages.sender_id IS '发送者用户ID';
COMMENT ON COLUMN n_direct_messages.content IS '消息文本内容';
COMMENT ON COLUMN n_direct_messages.is_deleted IS '是否删除';

CREATE TABLE n_direct_conversation_reads (
    conversation_id       NUMBER(19)      NOT NULL,
    user_id               NUMBER(19)      NOT NULL,
    last_read_message_id  NUMBER(19),
    last_read_at          TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT pk_direct_conversation_reads PRIMARY KEY (conversation_id, user_id),
    CONSTRAINT fk_direct_reads_conversation FOREIGN KEY (conversation_id)
        REFERENCES n_direct_conversations(conversation_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_reads_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_reads_message FOREIGN KEY (last_read_message_id)
        REFERENCES n_direct_messages(message_id) ON DELETE SET NULL
) TABLESPACE neko_data;

COMMENT ON TABLE n_direct_conversation_reads IS '私聊会话已读状态表';
COMMENT ON COLUMN n_direct_conversation_reads.conversation_id IS '会话ID';
COMMENT ON COLUMN n_direct_conversation_reads.user_id IS '用户ID';
COMMENT ON COLUMN n_direct_conversation_reads.last_read_message_id IS '最后已读消息ID';
COMMENT ON COLUMN n_direct_conversation_reads.last_read_at IS '最后已读时间';

CREATE INDEX idx_direct_conv_low_user ON n_direct_conversations(user_low_id, updated_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_direct_conv_high_user ON n_direct_conversations(user_high_id, updated_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_direct_messages_conv_time ON n_direct_messages(conversation_id, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_direct_messages_sender ON n_direct_messages(sender_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_direct_reads_user ON n_direct_conversation_reads(user_id, last_read_at DESC) TABLESPACE neko_index;

CREATE OR REPLACE TRIGGER trg_direct_conversations_id
BEFORE INSERT ON n_direct_conversations
FOR EACH ROW
BEGIN
    IF :NEW.conversation_id IS NULL THEN
        :NEW.conversation_id := seq_direct_conversation_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_direct_messages_id
BEFORE INSERT ON n_direct_messages
FOR EACH ROW
BEGIN
    IF :NEW.message_id IS NULL THEN
        :NEW.message_id := seq_direct_message_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_direct_conversations_updated
BEFORE UPDATE ON n_direct_conversations
FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_direct_messages_updated
BEFORE UPDATE ON n_direct_messages
FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/
