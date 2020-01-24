# TCP Throughput Limitation Analysis for [FlowScope](https://github.com/emmericp/FlowScope)

Scripts to perform TCP throughput limitation analysis [as described in our paper](https://www.net.in.tum.de/fileadmin/bibtex/publications/papers/bauer_noms2020.pdf)(NOMS 2020, [BibTeX](https://www.net.in.tum.de/publications/bibtex/Bau2020_NOMS.bib)).

## Usage

* Install [FlowScope](https://github.com/emmericp/FlowScope). An already adapted version providing larger hash table entry size can be [found here](https://github.com/nextl00p/FlowScope/).
* `./libmoon/build/libmoon lua/flowscope.lua path/to/scripts/rca.lua $DPDK-Interface `

