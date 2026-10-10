# ficha

Scripts da **Ficha Técnica** do yCODEX Tester.

Coletam as informações da máquina (marca, modelo, serial, asset tag, CPU, memória,
discos, vídeo, tela, webcam, biometria, rede, áudio, bateria, Bluetooth, NFC,
touchpad/trackpoint, teclado…) e abrem o site com a ficha já preenchida.

Nada é enviado para servidor: os dados vão no próprio link, depois do `#`,
que o navegador não manda para lugar nenhum.

## Uso

Não precisa copiar daqui: a aba **Ficha** do site mostra o comando certo para o
sistema da máquina, já com o endereço do site.

**Windows** (PowerShell):

```powershell
$ycSite='https://SEU-SITE/'; irm https://raw.githubusercontent.com/yC0D3X/ficha/main/ficha.ps1 | iex
```

**macOS / Linux** (Terminal):

```bash
curl -fsSL https://raw.githubusercontent.com/yC0D3X/ficha/main/ficha.sh | bash -s -- 'https://SEU-SITE/'
```

## Observações

- **Windows:** não precisa de administrador (a saúde da bateria vem do `powercfg /batteryreport`).
- **Linux:** número de série e detalhes dos pentes de memória exigem root; o script
  pergunta antes de usar `sudo` (dá para responder "N" e seguir sem eles).
- **macOS:** usa só ferramentas do sistema (`system_profiler`, `ioreg`, `diskutil`).
- Sem o endereço do site, o script mostra um código para colar em
  "Importar código manualmente" na ficha.
