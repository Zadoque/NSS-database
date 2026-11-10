# Catálogo de consultas e desempenho

## Consulta de bairros

Endpoint:

```text
GET /api/v1/epidemiology/neighborhoods
```

Filtros principais:

```text
disease, year, municipalityCode, districtCode, sex, ageBand
```

O Java executa uma consulta de totais e outra consulta agrupada por bairro. Para um município específico, o `batch_id` corrente deve ser obtido uma única vez por subconsulta escalar. Para consultas nacionais ou por região, o filtro precisa continuar aceitando vários municípios.

## Índices relevantes

O índice territorial segue a ordem dos filtros mais seletivos:

```sql
CREATE INDEX idx_fato_casos_territorio_recorte
ON analytics.fato_casos (
    disease_codigo,
    ano,
    cd_mun,
    notification_district_id,
    cd_sexo,
    batch_id
)
INCLUDE (
    notification_neighborhood_id,
    notification_territory_status,
    cases_total
);
```

## Benchmark registrado

Recorte usado:

```text
DENG / 2024 / município 3304557 / distrito IBGE_DIST_330455705
```

Hardware do ambiente de referência: Intel(R) Core(TM) i7-2600 CPU @ 3.40GHz,
com 4 threads disponíveis e 15 GiB de RAM.

Resultados observados no ambiente local:

| Consulta | Plano anterior | Plano otimizado |
|---|---:|---:|
| Totais do distrito | ~65,6 ms | ~29,6 ms |
| Agregação por bairros | ~230 ms | ~60 ms com `work_mem=64MB` |

Com `work_mem=4MB`, o PostgreSQL usa `external merge` e grava aproximadamente 3,1 MB temporários. Com `work_mem=64MB`, usa `quicksort` em memória, com aproximadamente 7,7 MB usados.

Esses números são referências do ambiente de teste, não SLO universal. Novos benchmarks devem informar hardware, volume, filtros, cache e configuração de `work_mem`.

## Diagnóstico

Use:

```sql
EXPLAIN (ANALYZE, BUFFERS)
<consulta>;
```

Observe principalmente:

- `Execution Time`;
- `Index Scan` ou `Index Only Scan`;
- `Rows Removed by Filter`;
- `loops` em `Nested Loop`;
- `Sort Method` e uso de arquivos temporários;
- `Buffers: shared hit/read`.
