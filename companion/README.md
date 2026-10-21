# Stremio Roku Companion — CachyOS / Arch Linux

O companion executa no PC que fica na mesma rede do Roku. Ele consulta os catálogos e add-ons, encaminha streams e pode converter torrents para HLS via FFmpeg.

## 1. Dependências no CachyOS

```sh
sudo pacman -Syu
sudo pacman -S --needed git nodejs npm curl unzip ffmpeg docker
```

Node.js 20 ou superior é obrigatório. FFmpeg é opcional, mas recomendado para tentar converter torrents em HLS. O Docker só é necessário se você ainda não tiver um Stremio Streaming Server acessível localmente na porta 11470.

## 2. Obter e iniciar o projeto

```sh
git clone https://github.com/VitorMartinsAlves/stremio-port.git
cd stremio-port
```

Confirme o Streaming Server:

```sh
curl -i --max-time 3 http://127.0.0.1:11470/heartbeat
```

Se não responder, você pode iniciar o servidor oficial pelo Docker:

```sh
sudo systemctl enable --now docker
sudo docker pull stremio/server:latest
sudo docker run -d \
  --name stremio-streaming-server \
  --restart unless-stopped \
  -p 127.0.0.1:11470:11470 \
  -p 127.0.0.1:12470:12470 \
  stremio/server:latest
curl -i --max-time 5 http://127.0.0.1:11470/heartbeat
```

Se o contêiner já existir, use `sudo docker start stremio-streaming-server` em vez de executar um segundo `docker run`.

Inicie o companion:

```sh
sh ./companion/start-linux.sh
```

Mantenha o terminal aberto. O serviço mostra a URL do painel, os endereços IP da rede local e um PIN de seis dígitos.

## 3. Painel e Roku

1. Abra no PC o endereço local exibido, normalmente `http://127.0.0.1:17890/`.
2. Digite o PIN e pressione **Testar servidor**.
3. Cadastre os manifestos dos add-ons, valide e salve a lista.
4. No Roku, instale `dist/stremio-roku-sideload.zip` pelo Development Application Installer.
5. No canal, pressione `*` → **Mais opções** → **Conectar ao PC**, informe o endereço LAN do companion e o PIN.

**Use o IP LAN do PC no Roku, não `127.0.0.1`.** Mantenha o PC e o serviço ligados durante a reprodução.

## 4. Verificações úteis

```sh
npm --prefix companion run check
npm --prefix companion run test:smoke
curl -i --max-time 3 http://127.0.0.1:17890/api/health
ss -ltnp | grep -E '11470|12470|17890'
```

O serviço usa apenas módulos nativos do Node.js; não é necessário executar `npm install`. Se o Roku não conectar, permita TCP na porta 17890 somente na rede local. Não encaminhe as portas do companion ou do Streaming Server para a Internet.

## Limitações

Este é um port experimental, não uma versão oficial do Stremio. É necessário cadastrar os add-ons manualmente. Sincronização de conta, biblioteca/histórico, DRM, alguns esquemas de autenticação e todos os formatos de mídia ainda não são suportados. FFmpeg ajuda com algumas fontes torrent, mas não garante compatibilidade para todos os streams.
