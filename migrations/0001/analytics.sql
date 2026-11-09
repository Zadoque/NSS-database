CREATE SCHEMA analytics;
CREATE SCHEMA analytics_animal;

CREATE TABLE analytics.dim_doenca (
    codigo VARCHAR(4) PRIMARY KEY,
    nome VARCHAR(50) NOT NULL
);
CREATE TABLE analytics.dim_municipio (
    cd_mun CHAR(7) PRIMARY KEY,
    nm_mun VARCHAR(100) NOT NULL,
    cd_uf CHAR(2) NOT NULL,
    nm_uf VARCHAR(50) NOT NULL
);
CREATE TABLE analytics.dim_unidade_saude (
    cd_unidade CHAR(7) PRIMARY KEY,
    nm_unidade VARCHAR(200),
    razao_social VARCHAR(200),
    tp_unidade SMALLINT,
    cd_mun CHAR(7) REFERENCES analytics.dim_municipio(cd_mun)
);
CREATE TABLE analytics.dim_classificacao (
    codigo VARCHAR(2) PRIMARY KEY,
    descricao VARCHAR(100) NOT NULL
);
CREATE TABLE analytics.dim_evolucao (
    codigo VARCHAR(2) PRIMARY KEY,
    descricao VARCHAR(100) NOT NULL
);

INSERT INTO analytics.dim_unidade_saude (cd_unidade, nm_unidade)
VALUES ('0000000', 'Não identificado');
INSERT INTO analytics.dim_classificacao (codigo, descricao)
VALUES ('NI', 'Não informado');
INSERT INTO analytics.dim_evolucao (codigo, descricao)
VALUES ('NI', 'Não informado');

CREATE TABLE analytics.fato_casos (
    id BIGSERIAL PRIMARY KEY,
    disease_codigo VARCHAR(4) NOT NULL REFERENCES analytics.dim_doenca(codigo),
    ano SMALLINT NOT NULL,
    mes SMALLINT NOT NULL,
    cd_mun CHAR(7) NOT NULL REFERENCES analytics.dim_municipio(cd_mun),
    cd_unidade CHAR(7) NOT NULL DEFAULT '0000000' REFERENCES analytics.dim_unidade_saude(cd_unidade),
    cd_classificacao VARCHAR(2) NOT NULL DEFAULT 'NI' REFERENCES analytics.dim_classificacao(codigo),
    cd_evolucao VARCHAR(2) NOT NULL DEFAULT 'NI' REFERENCES analytics.dim_evolucao(codigo),
    cases_total INTEGER NOT NULL,
    batch_id VARCHAR(20) NOT NULL,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    cd_sexo VARCHAR(1) NOT NULL DEFAULT 'I',
    semana_notif INTEGER NOT NULL DEFAULT 0,
    ano_nascimento SMALLINT NOT NULL DEFAULT 0,
    age_band VARCHAR(8) NOT NULL DEFAULT 'NI',
    notification_district_id VARCHAR(80),
    notification_neighborhood_id VARCHAR(100),
    notification_territory_status VARCHAR(40) NOT NULL DEFAULT 'UNMAPPED_NOTIFICATION_UNIT',
    CONSTRAINT fato_casos_unique UNIQUE (
        disease_codigo, ano, mes, cd_mun, cd_unidade, cd_classificacao,
        cd_evolucao, cd_sexo, semana_notif, ano_nascimento, age_band,
        notification_district_id, notification_neighborhood_id,
        notification_territory_status
    )
);
CREATE INDEX idx_fato_casos_municipio_ano_mes
    ON analytics.fato_casos (cd_mun, ano, mes);
CREATE INDEX idx_fato_casos_doenca ON analytics.fato_casos (disease_codigo);
CREATE INDEX idx_fato_casos_territorio_recorte
    ON analytics.fato_casos (
        disease_codigo, ano, cd_mun, notification_district_id, cd_sexo, batch_id
    )
    INCLUDE (notification_neighborhood_id, notification_territory_status, cases_total);

CREATE TABLE analytics.reference_catalog_releases (
    catalog_id VARCHAR(100) PRIMARY KEY,
    sha256 VARCHAR(64) NOT NULL,
    reference_year SMALLINT NOT NULL,
    source_name VARCHAR(200) NOT NULL,
    source_url VARCHAR(500) NOT NULL,
    retrieved_at TIMESTAMPTZ NOT NULL,
    registered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    content_sha256 VARCHAR(64)
);

CREATE TABLE analytics.pipeline_publications (
    disease_codigo VARCHAR(4) NOT NULL REFERENCES analytics.dim_doenca(codigo),
    ano SMALLINT NOT NULL,
    cd_mun CHAR(7) NOT NULL,
    batch_id VARCHAR(20) NOT NULL,
    source_extracted_at TIMESTAMPTZ NOT NULL,
    published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    groups_total BIGINT NOT NULL CHECK (groups_total >= 0),
    cases_total BIGINT NOT NULL CHECK (cases_total >= 0),
    ibge_catalog_id VARCHAR(100) REFERENCES analytics.reference_catalog_releases(catalog_id),
    ibge_catalog_sha256 VARCHAR(64),
    geographic_scope_type VARCHAR(30) NOT NULL DEFAULT 'MUNICIPALITIES',
    source_rows BIGINT NOT NULL DEFAULT 0 CHECK (source_rows >= 0),
    resolved_rows BIGINT NOT NULL DEFAULT 0 CHECK (resolved_rows >= 0),
    discarded_rows BIGINT NOT NULL DEFAULT 0 CHECK (discarded_rows >= 0),
    aggregation_reduction BIGINT NOT NULL DEFAULT 0 CHECK (aggregation_reduction >= 0),
    invalid_municipality_rows BIGINT NOT NULL DEFAULT 0 CHECK (invalid_municipality_rows >= 0),
    out_of_scope_rows BIGINT NOT NULL DEFAULT 0 CHECK (out_of_scope_rows >= 0),
    uf_mismatch_rows BIGINT NOT NULL DEFAULT 0 CHECK (uf_mismatch_rows >= 0),
    geographic_scope_sha256 VARCHAR(64),
    PRIMARY KEY (disease_codigo, ano, cd_mun, batch_id)
);
CREATE INDEX idx_pipeline_publications_recorte_data
    ON analytics.pipeline_publications (disease_codigo, ano, cd_mun, source_extracted_at DESC);

CREATE TABLE analytics.pipeline_execution_metrics (
    disease_codigo VARCHAR(4) NOT NULL REFERENCES analytics.dim_doenca(codigo),
    ano SMALLINT NOT NULL,
    batch_id VARCHAR(20) NOT NULL,
    source_extracted_at TIMESTAMPTZ NOT NULL,
    published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    geographic_scope_type VARCHAR(30) NOT NULL,
    geographic_scope_sha256 VARCHAR(64) NOT NULL,
    ibge_catalog_id VARCHAR(100),
    ibge_catalog_sha256 VARCHAR(64),
    source_rows BIGINT NOT NULL CHECK (source_rows >= 0),
    resolved_rows BIGINT NOT NULL CHECK (resolved_rows >= 0),
    discarded_rows BIGINT NOT NULL CHECK (discarded_rows >= 0),
    aggregation_reduction BIGINT NOT NULL CHECK (aggregation_reduction >= 0),
    invalid_municipality_rows BIGINT NOT NULL CHECK (invalid_municipality_rows >= 0),
    out_of_scope_rows BIGINT NOT NULL CHECK (out_of_scope_rows >= 0),
    uf_mismatch_rows BIGINT NOT NULL CHECK (uf_mismatch_rows >= 0),
    PRIMARY KEY (disease_codigo, ano, batch_id)
);
CREATE INDEX idx_pipeline_execution_metrics_recorte_data
    ON analytics.pipeline_execution_metrics (disease_codigo, ano, source_extracted_at DESC);

CREATE TABLE analytics.pipeline_current_publication (
    disease_codigo VARCHAR(4) NOT NULL REFERENCES analytics.dim_doenca(codigo),
    ano SMALLINT NOT NULL,
    cd_mun CHAR(7) NOT NULL REFERENCES analytics.dim_municipio(cd_mun),
    batch_id VARCHAR(20) NOT NULL,
    source_extracted_timestamp TIMESTAMPTZ NOT NULL,
    added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (disease_codigo, ano, cd_mun)
);
CREATE INDEX idx_pipeline_current_publication_batch
    ON analytics.pipeline_current_publication (disease_codigo, ano, batch_id);

CREATE TABLE analytics_animal.fato_esporo (
    id BIGSERIAL PRIMARY KEY,
    data_notificacao TIMESTAMP NOT NULL,
    especie VARCHAR(20) NOT NULL,
    sexo_animal VARCHAR(20) NOT NULL,
    idade_animal VARCHAR(20) NOT NULL,
    castrado VARCHAR(20) NOT NULL
);
