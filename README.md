# Ethereum Kurtosis Traffic Control

**Ethereum Kurtosis Traffic Control** is designed to facilitate experimentation with Ethereum clients (Geth, Prysm, etc.)
under network constraints. It is forked from the excellent [docker-tc tool](https://github.com/lukaszlach/docker-tc),
and it is meant to be used with the [Ethereum Kurtosis package](https://github.com/ethpandaops/ethereum-package).

## Usage

First, run Kurtosis to set up your local test network.

```
kurtosis run github.com/ethpandaops/ethereum-package --args-file downloaded_demo_config.yaml
```

Control EL node resources by setting uplink, downlink, and/or delay at any time. Changes are applied immediately.
```
sudo bin/kurtosis-tc.sh -e --downlink=50mbit --uplink=20mbit --delay=50ms
```

Parameters are optional: if not specified, values are reset to non-limited on every new invocation.
```
sudo bin/kurtosis-tc.sh -e --delay=200ms
```

Individual containers can also be changed by name pattern. E.g.
```
sudo bin/kurtosis-tc.sh -i "^cl-0*1" --delay=100ms
```
Note: "0*" because numbering scheme uses digits based on the number of clients.

For more details, see [the presentation](https://drive.google.com/file/d/1t4FW6CjdA0W54t9Z0z880PBTJt_2I8tM/view?usp=drive_link).

For other features of docker-tc, see the [original readme](https://github.com/lukaszlach/docker-tc).

## Licence

MIT License

Copyright (c) 2025 Csaba Kiraly. \
Copyright (c) 2018-2019 Łukasz Lach <llach@llach.pl>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
