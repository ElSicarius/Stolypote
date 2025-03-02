# Stolypote


A stolen/refactored/golang version of laluka's Broneypote https://github.com/laluka/broneypote


-> Even if I've tried to maximize the security, I'm still not responsible for any damage this tool can cause to your network ! It's a honeypot, it's supposed to be attacked and to be a target for malicious actors. Use it at your own risks.

# Installation

-> On a brand new VPS from Digitalovean/Linode/whatever...
-> Isolate it from anything critical from your network !

```bash

git clone https://github.com/ElSicarius/Stolypote
cd Stolypote

chmod +x start.sh

```

Then start everything with your domain name and port ranges:

```bash
./start.sh -p "80,443,9999" -d "example.com"

```

```bash
./start.sh -f ports/top1000.txt -d "example.com"

```

```bash
./start.sh -p "20-65534" -d "example.com"

```