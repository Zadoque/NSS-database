# Regras de execução do NSS

- Trabalhe na etapa aprovada em ambiente isolado. Preserve alterações existentes e não troque o ambiente ativo sem aprovação explícita.
- Registre critérios de aceite antes de alterar comportamento. Mudanças em contratos de schema, autenticação ou interpretação epidemiológica exigem aprovação.
- Use revisão independente de QA em modo de leitura. Para metas de desempenho, solicite revisão independente da comparação e da evidência.
- Rode as verificações relevantes ao diff. Use PostgreSQL e Redis reais para os contratos críticos e testes de mutação dirigidos quando aplicáveis. Verificações não executadas ficam pendentes.
- Compare alternativas no mesmo snapshot e nas mesmas condições. Confirme paridade antes de medir desempenho.
- Registre no PR os comandos, resultados, achados e limitações. As verificações obrigatórias devem passar na revisão integrada. Não reduza critérios para contornar falhas.

## Banco de dados

Este repositório define o schema, papéis, permissões e seeds da versão inicial. Use apenas fontes versionadas para derivar o DDL. Valide instalação limpa, reexecução, checksum e isolamento de privilégios em PostgreSQL descartável.
