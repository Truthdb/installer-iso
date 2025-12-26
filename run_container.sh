docker run --rm -it \
  --platform=linux/amd64 \
  -v "$PWD/..":/work \
  -w /work/installer-iso \
  ubuntu:24.04 bash
  