# gravador_cameras

Coleção de scripts Bash para **monitorar e gravar câmeras IP (RTSP)** em uma rede
local, com foco em câmeras/DVRs que mudam de endereço IP com frequência
(DHCP): o endereço é descoberto a partir do **MAC address**, não do IP fixo.

O projeto tem três scripts independentes:

| Script        | Função                                                                 |
|---------------|------------------------------------------------------------------------|
| `camera.sh`   | Abre todas as câmeras ao vivo com `ffplay` (janelas), reconectando sozinho |
| `gravador.sh` | Grava **uma** câmera em arquivos `.mkv` segmentados, 24 h por dia      |
| `limpeza.sh`  | Apaga as pastas de vídeo mais antigas que N dias                        |

## Funcionalidades

- **Descoberta de câmera por MAC address** (`arp-scan` como fonte primária e a
  tabela ARP do kernel — `ip neigh` — como alternativa sem privilégios).
- **Reconexão automática**: se a câmera cair, o script reconecta em 5 s; se ela
  não for encontrada na rede, tenta de novo a cada 10 s.
- **Gravação segmentada** em `.mkv` (10 min por padrão), com `-c:v copy`
  (sem reencode de vídeo, custo de CPU mínimo) e nome de arquivo com data/hora.
- **Virada de dia automática**: um `timeout -s INT` encerra o `ffmpeg` na
  meia-noite para que o último arquivo seja fechado corretamente, e a gravação
  recomeça já na pasta do novo dia.
- **Pasta por câmera e por dia**: `<BASE_DIR>/<camX>/AAAA-MM-DD/<camX>_AAAA-MM-DD_HH-MM-SS.mkv`.
- **Compatibilidade com ffmpeg 4.x e 5.x+**: detecta se o demuxer RTSP aceita
  `-stimeout` ou `-timeout` em tempo de execução.
- **Privilégio mínimo**: no `camera.sh` só o `arp-scan` roda como root (via
  `sudo`), e a senha é pedida uma única vez; o restante executa como usuário comum.
- **Cache de varredura de rede** (`camera.sh`): as câmeras compartilham o mesmo
  resultado de `arp-scan` por 30 s, evitando varrer a rede uma vez por câmera.
- **Encerramento limpo** com `Ctrl+C`/`SIGTERM` (traps que finalizam o `ffmpeg`
  e removem arquivos temporários).

## Estrutura do projeto

```
gravador_cameras/
├── camera.sh      # visualização ao vivo de todas as câmeras (ffplay)
├── gravador.sh    # gravação contínua de uma câmera (ffmpeg)
├── limpeza.sh     # retenção: apaga pastas de dias antigos
└── cameras.conf   # configuração das câmeras (MAC/IP, usuário, senha, canal, stream)
```

## Requisitos

- **Bash 4+** (usa *arrays associativos*: `declare -A`).
- **ffmpeg** — gravação (`gravador.sh`).
- **ffplay** — visualização (`camera.sh`, vem junto com o ffmpeg).
- **arp-scan** — opcional, mas recomendado para descobrir o IP pelo MAC.
- **iproute2** (`ip neigh`, `ip route`) — usado como alternativa ao arp-scan.
- **flock** (util-linux) — opcional, evita varreduras simultâneas duplicadas.
- `sudo` — apenas se você rodar `camera.sh` como usuário comum e quiser usar o
  `arp-scan`.

Instalação das dependências:

```bash
# Debian / Ubuntu
sudo apt install ffmpeg arp-scan iproute2 util-linux

# Fedora
sudo dnf install ffmpeg arp-scan iproute util-linux

# Arch
sudo pacman -S ffmpeg arp-scan iproute2 util-linux
```

## Instalação

```bash
git clone https://github.com/Gustavovieira22/gravador_cameras.git
cd gravador_cameras
chmod +x camera.sh gravador.sh limpeza.sh
```

O repositório já vem com os scripts com permissão de execução; o `chmod` acima
só é necessário se as permissões forem perdidas.

## Configuração

### `cameras.conf` (usado por `gravador.sh`)

```bash
BASE_DIR="/home/calango/DVR/videos"   # raiz onde os vídeos são gravados
SEG_TIME=600                          # duração de cada segmento, em segundos

declare -A CAM_IP CAM_USER CAM_PASS CAM_CHANNEL CAM_STREAM

CAM_IP[cam1]="00:12:43:A4:92:05"       # MAC address OU um IP fixo
CAM_USER[cam1]="seu_usuario"
CAM_PASS[cam1]="sua_senha"
CAM_CHANNEL[cam1]="1"                  # canal no DVR
CAM_STREAM[cam1]="0"                   # 0 = principal, 1 = secundário (sub-stream)
```

- **`CAM_IP` aceita MAC ou IP.** Se o valor tiver formato de MAC
  (`xx:xx:xx:xx:xx:xx`), o script resolve o IP atual na rede a cada tentativa;
  caso contrário, o valor é usado como host/endereço diretamente.
- **`CAM_STREAM`**: usar o sub-stream (geralmente `1`) reduz muito a banda e o
  espaço em disco.
- O arquivo é criado com permissão `600` porque contém senhas.

### Caminho do arquivo de configuração

`gravador.sh` carrega a configuração de um caminho **fixo**:

```bash
source /home/calango/DVR/cameras.conf
```

Então, antes de usar, faça uma das duas coisas:

```bash
# opção 1: ajustar a linha 10 do gravador.sh para o caminho do seu clone
# opção 2: manter o conf no local esperado
mkdir -p /home/calango/DVR
cp cameras.conf /home/calango/DVR/cameras.conf
chmod 600 /home/calango/DVR/cameras.conf
```

`limpeza.sh` não lê o `cameras.conf`: ele usa as variáveis de ambiente
`BASE_DIR` (padrão `/home/calango/DVR/videos`) e `DAYS` (padrão `15`).

### `camera.sh` (visualização ao vivo)

Este script é independente do `cameras.conf` e tem sua configuração no topo do
próprio arquivo:

```bash
USER="seu_usuario"
PASS_PATH="sua_senha"
CHANNEL="2"
STREAM="1"

declare -A CAMERAS=(
    [cam1]="00:12:43:A4:92:05"
    [cam2]="00:12:43:A9:BA:FF"
)
```

> **Atenção:** a URL RTSP montada no `camera.sh` segue o padrão
> `rtsp://admin:suasenha@IP:554/user=<USER>_password=<PASS>_channel=<CH>_stream=<ST>.sdp`,
> que **depende do fabricante** (alguns modelos usam `.sdb` em vez de `.sdp`, ou
> esperam as credenciais apenas em `user:`/`password:`). Ajuste a linha da
> variável `URL` dentro de `run_camera()` conforme o seu equipamento — e troque
> `admin:suasenha` pelas credenciais corretas.

## Uso

### 1. Assistir todas as câmeras ao vivo

```bash
./camera.sh
```

Abre uma janela `ffplay` por câmera declarada em `CAMERAS`. Sem argumentos.
Pressione `Ctrl+C` para encerrar todas as janelas de uma vez.

### 2. Gravar uma câmera

```bash
./gravador.sh cam1
```

- Grava até a meia-noite, quando reinicia automaticamente na pasta do novo dia.
- Em caso de queda de conexão, reconecta em 5 s (mantendo os arquivos já gravados).
- Encerre com `Ctrl+C`; o `ffmpeg` recebe `SIGTERM` e finaliza o arquivo atual.

Para gravar várias câmeras, rode um processo por câmera (ver seção **Automação**).

### 3. Apagar vídeos antigos

```bash
./limpeza.sh --dry-run     # apenas mostra o que seria apagado
./limpeza.sh               # apaga de verdade
```

Remove as pastas no formato `AAAA-MM-DD` **anteriores** à data de corte
(`hoje - DAYS`); a pasta exatamente na data de corte é preservada.

```bash
# usando outro local e outra retenção
BASE_DIR=/mnt/hd/dvr DAYS=30 ./limpeza.sh --dry-run
```

> O cabeçalho do `limpeza.sh` menciona `./limpar_videos.sh`; o nome real do
> arquivo é `limpeza.sh`.

### Exemplo de saída em disco

```
/home/calango/DVR/videos/
├── cam1/
│   ├── 2026-11-24/
│   │   ├── cam1_2026-11-24_00-00-00.mkv
│   │   └── cam1_2026-11-24_00-10-00.mkv
│   └── 2026-11-25/
│       └── cam1_2026-11-25_00-00-00.mkv
└── cam2/
    └── 2026-11-25/
        └── cam2_2026-11-25_00-00-00.mkv
```

## Como funciona

### Descoberta do IP pelo MAC (`gravador.sh` e `camera.sh`)

1. Lê o endereço do `cameras.conf` / do array `CAMERAS`. Se **não** for um MAC,
   usa o valor como host e pronto.
2. Se for MAC, tenta o `arp-scan --localnet --plain --quiet` na interface de
   saída padrão (`ip route | awk '/default/ {print $5}'`).
3. Se o `arp-scan` não estiver disponível ou não achar nada, cai para a tabela
   ARP do kernel: `ip neigh`, ignorando entradas `FAILED`/`INCOMPLETE`.
4. No `camera.sh`, o resultado da varredura é cacheado por 30 s em
   `${TMPDIR:-/tmp}/camera.sh.arp.$UID` (com trava via `flock`), para que todas
   as câmeras reaproveitem a mesma varredura.
5. A resolução é refeita **a cada tentativa de conexão**, então a câmera pode
   trocar de IP sem precisar reiniciar o script.

### Privilégios (`camera.sh`)

O `arp-scan` precisa de socket raw (root). O script pede a senha do `sudo` uma
única vez no início e mantém a credencial viva com `sudo -n -v` a cada 60 s em
background. Se não houver terminal, `sudo` estiver indisponível ou a senha for
negada, ele apenas avisa e segue usando `ip neigh`. Para não digitar senha
nunca mais:

```bash
sudo setcap cap_net_raw+p "$(command -v arp-scan || echo /usr/sbin/arp-scan)"
# ou uma regra NOPASSWD no sudoers apenas para o arp-scan
```

### Gravação (`gravador.sh`)

- Monta a URL RTSP: `rtsp://<host>/user=<USER>&password=<PASS>&channel=<CH>&stream=<ST>.sdb`.
- Roda `ffmpeg` com `-rtsp_transport tcp`, timeout de I/O de 10 s
  (`-stimeout` ou `-timeout`, conforme a versão) e `-c:v copy` — o vídeo é
  copiado sem reencode; **apenas o áudio é convertido para AAC**.
- Segmenta com `-f segment -segment_time $SEG_TIME -segment_atclocktime 1
  -reset_timestamps 1 -strftime 1`, gerando `.mkv` com timestamp no nome.
- Envolve o `ffmpeg` em `timeout -s INT -k 10 <segundos até a meia-noite>`:
  à meia-noite chega um `SIGINT`, o `ffmpeg` fecha o arquivo corretamente e o
  laço recomeça já com a pasta do dia seguinte (se faltarem menos de 2 s para a
  meia-noite, ele apenas espera a virada).
- Se o processo cair no mesmo dia, é tratado como queda de conexão: reconecta
  em 5 s.

### Limpeza (`limpeza.sh`)

Calcula `CUTOFF=$(date -d "-${DAYS} days" +%F)` e apaga as pastas
`<BASE_DIR>/<cam>/AAAA-MM-DD` cujo nome seja lexicograficamente menor que o
corte (o formato `AAAA-MM-DD` permite comparação de texto). Só mexe em pastas
com nome de data válido, valida `BASE_DIR`/`DAYS` e recusa `BASE_DIR=/`.

## Automação

### Gravar várias câmeras

Cada `gravador.sh` grava **uma** câmera, então abra um processo por câmera:

```bash
for cam in cam1 cam2; do
  nohup ./gravador.sh "$cam" >> "/var/log/gravador-$cam.log" 2>&1 &
done
```

Em produção, prefira um serviço `systemd` por câmera (exemplo — ajuste os
caminhos e usuário, e crie antes o `/home/calango/DVR/cameras.conf`):

```ini
# /etc/systemd/system/gravador@.service
[Unit]
Description=Gravador da camera %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=calango
ExecStart=/home/calango/Documentos/gravador_cameras/gravador.sh %i
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gravador@cam1.service gravador@cam2.service
journalctl -u gravador@cam1 -f
```

### Retenção diária (cron)

```bash
# todo dia às 04:00, mantendo 15 dias
0 4 * * * BASE_DIR=/home/calango/DVR/videos DAYS=15 /home/calango/Documentos/gravador_cameras/limpeza.sh >> /var/log/limpeza-cameras.log 2>&1
```

## Segurança

- **As senhas ficam em texto plano** (`cameras.conf` e constantes no topo do
  `camera.sh`). Mantenha o `cameras.conf` com `chmod 600` e fora de repositórios
  públicos; os valores versionados são apenas placeholders (`seu_usuario`,
  `sua_senha`).
- Em `systemd`, evite senhas na linha de comando (o `ps` mostra os argumentos);
  prefira o arquivo de configuração.
- Se possível, crie um usuário dedicado na câmera/DVR para as gravações em vez
  de usar o `admin`.
- O `sudo` é usado apenas para o `arp-scan`; usar `setcap`/NOPASSWD é menos
  invasivo do que rodar tudo como root.

## Solução de problemas

| Sintoma | Causa provável / solução |
|---|---|
| `não encontrada na rede. Nova tentativa em 10s...` | MAC errado, câmera em outra sub-rede/VLAN, isolamento de clientes no Wi-Fi ou tabela ARP vazia. Dê um `ping` na câmera para popular o ARP e confira com `ip neigh` e `arp-scan --localnet`. |
| `aviso: sem permissão para o arp-scan` | Senha do `sudo` não informada (sem terminal) ou negada. Use `setcap` ou rode a partir de um terminal interativo. |
| `aviso: a credencial do sudo expirou` | O keepalive morreu; reinicie o script ou use `setcap`/NOPASSWD. |
| `Unrecognized option 'stimeout'` / `'timeout'` | Não deveria ocorrer: a detecção é automática. Confira com `ffmpeg -h demuxer=rtsp \| grep -E 'stimeout\|timeout'`. |
| Vídeo não abre / erro de autenticação | URL RTSP do fabricante diferente (`.sdp` x `.sdb`, `user:`/`password:`, porta). Ajuste a linha da `URL`. |
| `ffplay` não abre janela | Precisa de sessão gráfica; via SSH use `ssh -X`/`-Y` ou apenas grave e assista depois. |
| Disco cheio | Reduza a retenção (`DAYS`), use o sub-stream (`stream=1`) — o tamanho total depende do bitrate da câmera. |
| Primeiro arquivo do dia com duração estranha | `-segment_atclocktime 1` corta nos múltiplos exatos de `SEG_TIME` (ex.: 00:00, 00:10, ...), então o segmento que cruza o início da gravação pode ser mais curto ou mais longo. |

## Limitações conhecidas

- Não há serviço `systemd`, instalador ou `Makefile` prontos — a integração é
  manual (exemplos acima).
- `camera.sh` usa sua própria lista de câmeras e seu próprio formato de URL; ele
  **não** lê o `cameras.conf`.
- `gravador.sh` depende do caminho absoluto `/home/calango/DVR/cameras.conf` e de
  um formato de URL RTSP específico (sufixo `.sdb`).
- A descoberta por MAC só funciona dentro do mesmo domínio de broadcast.
- Não há autenticação nem criptografia nos vídeos gerados; proteja o diretório
  com permissões adequadas.

## Licença

Este projeto não inclui arquivo de licença. Sem uma licença explícita, o código
permanece sob os direitos autorais do autor — entre em contato com o mantenedor
antes de reutilizá-lo.
