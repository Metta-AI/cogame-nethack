# Nethack post-training

`tools/export_posttrain.nim` plays ten complete native games per certified
variant. Each row contains the hosted system prompt, the fogged seat observation,
and a delver or bumbler plan accepted by the production directive parser. The
native driver executes every plan. Whole games stay in one split.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/nethack-posttrain tools/export_posttrain.nim
python3 tools/test_posttrain.py /tmp/nethack-posttrain
/tmp/nethack-posttrain /tmp/nethack-data 10 descend
```

The other certified variant is `minihack`. Ten games yielded 310 training and
82 validation decisions for `descend`, and 282 and 91 for `minihack`. The
largest examples used 1,702 and 1,686 tokens with a local Qwen2.5 tokenizer,
within 4,096 tokens. One CPU optimizer step on a tiny local model reduced
validation loss from 5.5883 to 5.4698 and 5.4463 to 5.3333, respectively.
These short runs verify the training path, not policy quality.

From a Metta checkout with `metta-posttrain` installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/nethack-data --output /tmp/nethack-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

The exporter uses the same observed ASCII map and message line as the hosted
player. Unvisited cells and undiscovered dungeon state stay hidden.
