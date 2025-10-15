FROM ocaml/opam:debian-12-ocaml-5.1

USER root

RUN apt-get update && apt-get install -y \
    curl \
    openssl \
    && curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && rm kubectl \
    && apt-get clean

USER opam
WORKDIR /home/opam/app

RUN opam install -y dune base64 yojson

COPY --chown=opam:opam dune-project dune main.ml ./

RUN eval $(opam env) && dune build && cp _build/default/main.exe ./provisioner

ENTRYPOINT ["./provisioner"]
