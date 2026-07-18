# Guia para iniciantes — fast-claude 🇧🇷

*Documentação para quem **não é desenvolvedor**. Sem jargão, passo a passo, do zero.*

---

## O que é isso?

O **Claude Code** é o assistente de programação da Anthropic que roda no seu computador. Com o tempo, ele pode ficar **lento**: demora pra responder, trava depois de editar um arquivo, fica pedindo permissão toda hora.

O **fast-claude** é um "kit de otimização" que resolve isso. Ele faz duas coisas:

1. **Ensina o Claude a se otimizar** — é uma *skill* (um manual que o próprio Claude lê). Você só diz *"Claude Code feels slow"* e ele aplica as correções certas.
2. **Prova que funcionou com números** — vem com um medidor (`benchmark.sh`) que compara o antes e o depois, num painel visual.

> **Analogia:** é como levar o carro numa oficina que primeiro mede tudo (consumo, tempo de resposta), depois faz UM ajuste por vez, e mede de novo pra provar que cada ajuste valeu a pena. Nada de "troca tudo e reza".

---

## Por que o Claude Code fica lento?

São 4 causas, e cada uma tem cura própria:

| Causa | O que acontece | Analogia |
|---|---|---|
| **1. Verificação após cada edição** | A cada arquivo editado, um "revisor" (hook) verifica o projeto INTEIRO em vez de só o arquivo mexido | Reler o livro todo pra revisar um parágrafo |
| **2. Bagagem no início da sessão** | Ferramentas conectadas (MCP, plugins, skills) que você nem usa são carregadas toda vez | Sair de casa com 5 malas pra ir na padaria |
| **3. Pedidos de permissão** | O Claude para e espera VOCÊ clicar "aprovar" para comandos inofensivos, tipo listar arquivos | Pedir autorização por escrito pra abrir uma gaveta |
| **4. Sessões longas** | Cada resposta reprocessa toda a conversa; conversa gigante = resposta lenta | Recontar a história inteira antes de cada frase nova |

O fast-claude ataca as 4 — **sem sacrificar qualidade nem segurança** (essa é a regra número 1 do projeto).

---

## Passo a passo: instalando

**O que você precisa ter:** um Mac ou Linux com o Claude Code já instalado, e o programa `jq` (um leitor de dados que o kit usa).

**1.** Abra o Terminal (no Mac: `Cmd + Espaço`, digite "Terminal", Enter).

**2.** Instale o `jq` (se já tiver, não faz mal repetir):

```bash
brew install jq
```

**3.** Baixe o fast-claude para a pasta de skills do Claude:

```bash
git clone https://github.com/leonardobissoli/fast-claude ~/.claude/skills/fast-claude
```

**4.** Pronto. Abra o Claude Code e diga:

> *"Claude Code feels slow"*  (ou: "o Claude Code está lento")

A skill dispara sozinha e o Claude te guia pelas correções, uma por vez.

---

## Passo a passo: medindo (o antes e depois)

De nada adianta "sentir" que ficou mais rápido — o kit mede de verdade. O fluxo tem 4 passos:

**1. Ligue o cronômetro.** No Terminal:

```bash
echo 'export FAST_CLAUDE_DEBUG=1' >> ~/.zshrc
```

Feche e abra o Terminal. A partir daí, cada verificação de arquivo fica registrada com seu tempo (num arquivo de log, invisível pra você).

**2. Use o Claude Code normalmente por um dia.** Depois, tire a "foto" do estado atual:

```bash
~/.claude/skills/fast-claude/scripts/benchmark.sh snapshot baseline
```

`baseline` = "linha de base", seu ponto de partida. Essa foto guarda: quanto tempo cada verificação levou, quanta "bagagem" a sessão carrega, quanto tempo você passou esperando permissões, quanto demora cada resposta.

**3. Aplique UMA otimização** (o Claude faz isso por você quando você diz que está lento). Use por mais um dia e tire outra foto, com o nome da mudança:

```bash
~/.claude/skills/fast-claude/scripts/benchmark.sh snapshot incremental-hook
```

**4. Compare:**

```bash
~/.claude/skills/fast-claude/scripts/benchmark.sh compare baseline incremental-hook
```

Sai uma tabela no Terminal com o antes, o depois e a diferença em %. Ou gere o painel visual:

```bash
~/.claude/skills/fast-claude/scripts/benchmark.sh report
```

Isso cria um arquivo `benchmark-dashboard.html` — clique duas vezes nele e abre no navegador.

> **Sem paciência pra esperar um dia?** `benchmark.sh hook caminho/do/arquivo.ts` mede a verificação de arquivo na hora, incluindo o "antes" e o "depois".

---

## Como ler o painel

![painel de exemplo](sample-benchmark.jpg)

- **Cada linha é uma "foto"** (snapshot) que você tirou, da mais antiga pra mais nova. No exemplo: `01-baseline` (antes de tudo) → `02-incremental-hook` → `03-mcp-trim` → `04-allowlist` (uma foto após cada otimização).
- **Barra menor = mais rápido = melhor.** Sempre. Barra clara = passado; barra escura = seu estado atual.
- **O selo ▼ verde** mostra quanto melhorou do início até agora (ex.: ▼ -68% = caiu 68%). ▲ vermelho = piorou (bom pra pegar mudança que deu errado).
- **Os 4 cartões do topo** são o resumo: tempo de verificação, bagagem de início de sessão, espera por permissões, tempo por resposta.
- **A linhazinha de tendência** mostra ONDE a queda aconteceu — se caiu logo depois da foto `03-mcp-trim`, foi aquela mudança que valeu.
- O próprio painel tem uma seção **"How to read this dashboard"** no topo com esse resumo.

No exemplo acima, a leitura é: a verificação de arquivo caiu de 4,2s pra 1,4s na otimização `02`, a bagagem de sessão caiu 35% na `03`, e a espera por permissões despencou 87% na `04`. Cada mudança provou seu valor.

---

## Isso é seguro?

Sim — e o projeto é teimoso quanto a isso. O que ele **se recusa** a fazer em nome da velocidade:

- **Não desliga verificações de código** — só as torna mais espertas (verificar apenas o que mudou).
- **Não libera comandos perigosos** — só automatiza aprovação de comandos de *leitura* (ver status, listar arquivos). Nada que modifique ou apague.
- **Não troca o modelo por um mais burro** — velocidade não pode custar qualidade de raciocínio.

---

## Problemas comuns

| Sintoma | Solução |
|---|---|
| "Não sei se instalou" | No Claude Code, digite: *"você conhece a skill fast-claude?"* |
| Comando `benchmark.sh` não encontrado | Use o caminho completo: `~/.claude/skills/fast-claude/scripts/benchmark.sh` |
| `jq not installed` | Rode `brew install jq` |
| Snapshot diz "no hook timings" | O cronômetro não estava ligado — refaça o passo 1 da medição e use o Claude por um tempo |
| Painel abre em branco | Gere de novo com `benchmark.sh report` — precisa de pelo menos 1 snapshot salvo |

---

## Glossário rápido

| Termo | Tradução pra humanos |
|---|---|
| **Skill** | Manual que o Claude lê pra aprender uma tarefa nova |
| **Hook** | Verificação automática que roda após cada edição de arquivo |
| **MCP** | Conectores que dão superpoderes ao Claude (Gmail, Notion…) — cada um carregado pesa na sessão |
| **Token** | "Palavrinha" que o modelo processa; mais tokens = mais lento e mais caro |
| **Contexto** | Tudo que o Claude carrega na memória durante a conversa |
| **Allowlist** | Lista de comandos pré-aprovados que não pedem sua permissão |
| **Snapshot** | Foto das medições num momento, pra comparar depois |
| **p50 / p95** | "Metade das vezes foi mais rápido que isso" / "quase sempre (95%) foi mais rápido que isso" |
| **Baseline** | Ponto de partida — a medição de antes de qualquer mudança |

---

*Dúvidas técnicas? O [README](../README.md) (em inglês) e o [SKILL.md](../SKILL.md) têm a versão completa para desenvolvedores.*
