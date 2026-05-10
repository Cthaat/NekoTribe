-- 允许媒体资源保存普通附件文件。
-- 适用于已执行过旧版建表脚本的 Oracle 数据库。

SET DEFINE OFF;

DECLARE
    PROCEDURE replace_media_type_check(
        p_table_name      IN VARCHAR2,
        p_constraint_name IN VARCHAR2
    ) IS
        v_table_count NUMBER;
    BEGIN
        SELECT COUNT(*)
        INTO v_table_count
        FROM user_tables
        WHERE table_name = p_table_name;

        IF v_table_count = 0 THEN
            RETURN;
        END IF;

        FOR item IN (
            SELECT DISTINCT c.constraint_name
            FROM user_constraints c
            JOIN user_cons_columns cc
                ON cc.constraint_name = c.constraint_name
                AND cc.table_name = c.table_name
            WHERE c.table_name = p_table_name
              AND c.constraint_type = 'C'
              AND cc.column_name = 'MEDIA_TYPE'
              AND (
                    c.constraint_name = p_constraint_name
                    OR (
                        LOWER(c.search_condition_vc) LIKE '%media_type%'
                        AND LOWER(c.search_condition_vc) LIKE '%image%'
                        AND LOWER(c.search_condition_vc) LIKE '%video%'
                        AND LOWER(c.search_condition_vc) LIKE '%audio%'
                        AND LOWER(c.search_condition_vc) LIKE '%gif%'
                    )
              )
        ) LOOP
            EXECUTE IMMEDIATE
                'ALTER TABLE ' || p_table_name ||
                ' DROP CONSTRAINT ' || item.constraint_name;
        END LOOP;

        EXECUTE IMMEDIATE
            'ALTER TABLE ' || p_table_name ||
            ' ADD CONSTRAINT ' || p_constraint_name ||
            ' CHECK (media_type IN (''image'', ''video'', ''audio'', ''gif'', ''file''))';

        EXECUTE IMMEDIATE
            'COMMENT ON COLUMN ' || p_table_name ||
            '.media_type IS ''媒体类型：image-图片，video-视频，audio-音频，gif-动图，file-普通附件''';
    END;
BEGIN
    replace_media_type_check('N_MEDIA_ASSETS', 'CK_MEDIA_ASSETS_MEDIA_TYPE');
    replace_media_type_check('N_MEDIA', 'CK_N_MEDIA_MEDIA_TYPE');
END;
/
