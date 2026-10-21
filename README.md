# Stremio para Roku — cliente Roku + companion no CachyOS

Este projeto é um port experimental do Stremio para Roku. O Roku roda o cliente nativo em BrightScript/SceneGraph; o CachyOS roda um serviço auxiliar que consulta catálogos/add-ons e encaminha a reprodução pelo Stremio Streaming Server. O PC precisa permanecer ligado durante a reprodução.

> **Importante:** não é o cliente oficial nem possui paridade total. Não importa automaticamente sua conta, biblioteca ou histórico do Stremio. Os add-ons precisam ser cadastrados manualmente. A compatibilidade final deve ser testada no Roku físico.

## Guia de instalação no CachyOS (recomendado)

Siga os passos nesta ordem. Todos os comandos abaixo são executados no terminal do CachyOS, exceto quando indicam o navegador do Roku ou do PC.

### 1. Instale as dependências

```sh
sudo pacman -Syu
sudo pacman -S --needed git nodejs npm zip unzip curl ffmpeg docker flatpak
```

- `nodejs` e `npm`: executam e testam o companion.
- `zip`/`unzip`: empacotam o aplicativo de sideload.
- `ffmpeg`: permite transcodificar torrents para HLS, melhorando a compatibilidade com codecs do Roku.
- `docker`: opção recomendada para executar o Streaming Server caso o Stremio que você já usa não exponha a API local na porta 11470.

Confirme as ferramentas:

```sh
node --version
npm --version
ffmpeg -version
docker --version
```

O companion requer Node.js 20 ou superior.

### 2. Baixe o projeto

```sh
git clone https://github.com/VitorMartinsAlves/stremio-port.git
cd stremio-port
```

Se já clonou o repositório anteriormente, atualize-o antes de continuar:

```sh
git pull
```

### 3. Instale o Stremio Desktop (opcional) e confirme o Streaming Server

Se quiser também usar o aplicativo Stremio no CachyOS, instale a versão oficial do Flathub:

```sh
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub com.stremio.Stremio
flatpak run com.stremio.Stremio
```

Abra o Stremio e entre na sua conta normalmente. **Este port não importa a conta nem sincroniza os add-ons automaticamente**; os manifestos usados pelo Roku devem ser cadastrados manualmente no painel do companion.

Agora confirme se o Streaming Server local já está acessível:

```sh
curl -i --max-time 3 http://127.0.0.1:11470/heartbeat
```

Se receber uma resposta HTTP, não inicie outro servidor imediatamente; pule para o passo 4 e confira o status no painel. Se aparecer erro de conexão, siga a alternativa Docker abaixo.

#### Alternativa: servidor oficial via Docker

Inicie o serviço Docker:

```sh
sudo systemctl enable --now docker
```

Baixe a imagem oficial do Streaming Server:

```sh
sudo docker pull stremio/server:latest
```

Crie o contêiner usando apenas loopback para não expor essas portas diretamente à rede:

```sh
sudo docker run -d \
  --name stremio-streaming-server \
  --restart unless-stopped \
  -p 127.0.0.1:11470:11470 \
  -p 127.0.0.1:12470:12470 \
  stremio/server:latest
```

Confirme que ele respondeu:

```sh
curl -i --max-time 5 http://127.0.0.1:11470/heartbeat
```

Se você já criou o contêiner anteriormente e o comando informar que o nome está em uso, inicie-o em vez de criá-lo novamente:

```sh
sudo docker start stremio-streaming-server
```

Referência do servidor: [Stremio/server-docker](https://github.com/Stremio/server-docker).

### 4. Crie e empacote o aplicativo Roku

O pacote do Roku pode ser baixado do GitHub Actions, mas você também pode compilá-lo no CachyOS. Para compilar localmente, instale o compilador BrightScript:

```sh
sudo npm install --global brighterscript
```

Depois rode os testes e crie os dois ZIPs:

```sh
npm --prefix companion run check
npm --prefix companion run test:smoke
bsc --create-package false --copy-to-staging false
sh ./scripts/package.sh
```

Os arquivos serão criados em:

- `dist/stremio-roku-sideload.zip` — o ZIP para enviar ao Roku.
- `dist/stremio-companion.zip` — pacote do serviço auxiliar.

### 5. Inicie o companion no CachyOS

No diretório do repositório, execute:

```sh
sh ./companion/start-linux.sh
```

Deixe esse terminal aberto. O serviço vai imprimir:
- URL local do painel, normalmente `http://127.0.0.1:17890/`;
- um ou mais endereços LAN, como `http://192.168.1.50:17890/`;
- um PIN de seis dígitos.

Use o endereço LAN para conectar o Roku. Não use `127.0.0.1` no Roku: nesse dispositivo, esse endereço aponta para o próprio Roku, não para o PC.

Se precisar encontrar o endereço IP manualmente:

```sh
ip -4 -brief address
```

Abra no navegador do PC o endereço local exibido, digite o PIN e pressione **Testar servidor**. O estado do Streaming Server deve mostrar conexão. O companion usa `http://127.0.0.1:11470` por padrão.

### 6. Cadastre seus add-ons

No painel web do companion:

1. Cole a URL do manifesto do add-on (normalmente termina em `/manifest.json`).
2. Clique em **Validar**.
3. Depois clique em **Salvar lista de add-ons**.
4. Se instalou o FFmpeg, habilite **Transcodificar torrents para HLS** e salve.

Use apenas add-ons em que confia. O port não importa automaticamente os add-ons da sua conta Stremio.

### 7. Instale o ZIP no Roku via sideload

1. Ative o **Developer Mode** do Roku e anote o IP mostrado na TV.
2. No PC, abra `http://IP-DO-ROKU`.
3. Entre no Development Application Installer com usuário `rokudev` e a senha configurada no Roku.
4. Envie `dist/stremio-roku-sideload.zip`.
5. Abra o canal **Stremio for Roku**.
6. Pressione `*` no controle, selecione **Mais opções** → **Conectar ao PC**.
7. Informe o endereço LAN e a porta impressos no terminal do CachyOS, por exemplo `http://192.168.1.50:17890`, e depois digite o PIN.

Escolha um filme ou episódio para consultar os streams dos add-ons cadastrados no companion.

## Instalação dos pacotes do GitHub Actions (sem compilar no CachyOS)

A cada atualização há artefatos em [GitHub Actions](https://github.com/VitorMartinsAlves/stremio-port/actions). Abra a execução bem-sucedida mais recente chamada **Build Roku app and PC companion** e baixe os artefatos `stremio-roku-sideload` e `stremio-companion`.

O download do Actions normalmente é um ZIP externo que contém o ZIP do aplicativo. Extraia o arquivo externo uma vez para obter `stremio-roku-sideload.zip` ou `stremio-companion.zip`. Para o tutorial acima, você pode usar o código clonado e executar o script de build localmente em vez de baixar os artefatos.

## Diagnóstico no CachyOS

Confira os serviços e portas:

```sh
curl -i --max-time 3 http://127.0.0.1:11470/heartbeat
curl -i --max-time 3 http://127.0.0.1:17890/api/health
ss -ltnp | grep -E '11470|12470|17890'
```

Se o Roku não consegue conectar ao companion:
- confirme que PC e Roku estão na mesma rede local;
- use o IP LAN do PC, não `127.0.0.1`;
- mantenha o terminal do companion aberto;
- confira se o firewall permite conexões TCP de entrada na porta `17890` **somente na rede local**;
- confira se o endereço LAN exibido pelo terminal está na interface de rede correta.

Se o painel abre, mas o Streaming Server aparece desconectado:
- confirme que `/heartbeat` responde na porta `11470`;
- confira a URL em **Configurações do Streaming Server** no painel;
- veja se outro serviço já ocupa a porta `11470` antes de iniciar outro contêiner.

Se a reprodução falhar:
- instale FFmpeg com `sudo pacman -S --needed ffmpeg`;
- habilite a transcodificação HLS no painel e salve;
- teste outra fonte/add-on, pois alguns serviços exigem autenticação, headers ou protocolos que o Roku não suporta;
- confirme que o PC não está suspenso e que a rede é estável.

Logs do contêiner Docker:

```sh
sudo docker logs --tail=100 stremio-streaming-server
```

## Arquitetura e recursos

- Cliente Roku nativo em BrightScript/SceneGraph.
- Catálogos Cinemeta, busca por título e seleção de episódios de séries.
- Catálogos e streams de add-ons configurados manualmente.
- Companion Node.js na LAN, com pareamento por PIN, painel web e diagnóstico.
- Proxy de streams diretos com requisições por intervalos de bytes e suporte a playlists HLS.
- Solicitações de torrents encaminhadas ao Streaming Server local.
- Transcodificação opcional de torrents para HLS/H.264/AAC por FFmpeg no PC.
- Leitura e tentativa de edição das configurações avançadas expostas pela API do Streaming Server.

## Limitações conhecidas

O projeto é experimental. Não implementa login do Stremio, sincronização de biblioteca/histórico, DRM, controle parental, importação automática da conta, todos os fluxos de autenticação de add-ons ou resolução de YouTube `ytId`. A transcodificação FFmpeg é aplicada ao caminho de torrents; streams diretos com codecs incompatíveis ainda podem falhar. O suporte a configurações do Streaming Server depende da versão em execução e o servidor pode recusar campos não suportados.

O companion foi projetado para uma rede doméstica confiável. **Não encaminhe as portas 17890, 11470 ou 12470 para a Internet.** Não exponha o serviço de streaming nem o painel web publicamente.
