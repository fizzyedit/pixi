# pixi, for an agent

What an agent needs to know to work in pixi well. People read it in the plugin store; agents read
it through fizzy's MCP bridge (plans#8).

## Drawing

Drawing is not generating. `pixi.draw` stamps a finished grid: every decision was made before the
first pixel landed. To draw, make marks with the tools, look at what they did, and decide the next
mark from what you saw. The picture comes out of the passes.

### The rules

- **Strokes, not rows.** Draw with `pixi.draw`'s `stroke`, `line`, `fill`, `rect`, `ellipse` and
  `clear` ops: marks made with a pen, a bucket, an eraser. Never `paint` with pixel rows while
  drawing; that stamps a finished picture.
- **Look between passes.** After each pass, look twice: `fizzy_capture` with the canvas for the
  whole impression, and `pixi.read` for exact pixels. The image shows whether it reads; the grid
  shows where it is wrong.
- **Plan after looking.** Write each pass's plan after the look before it, and name what it fixes:
  "the cap's runs go 3, 2, 1, 1, 2: make them 3, 2, 1, 1 then 2, 6". A plan written before you
  looked is a traced picture.

### Drawing beside the person

The person keeps working while you draw: their pointer, keys, tool, colours, brush and selection
stay theirs. So draw with commands, never with the pointer (`fizzy_act` clicks and strokes are for
testing the interface as a person uses it), and say everything in the call:

```json
{"id": "pixi.draw", "args": {"layer": "art", "ops": [
  {"stroke": {"points": [[8, 29], [11, 29], [12, 30], [14, 31]], "color": "#3a2a30", "size": 1}},
  {"fill": {"x": 28, "y": 34, "color": "#7b5236"}}]}}
```

- **Name the layer** (`layer`), give **colours as hex**, a stroke's **`size`** (and `square`). Never
  `pixi.setColors`, `setTool`, `setBrushSize`, `selectLayer` or `select`: they change the
  person's tool, not yours. Choose colours from `pixi.palettes` if you like; don't load one.
- **One pass is one `pixi.draw`**, one undo step the person can see and take back. It is shown
  drawn, with a pen of its own, while the person's cursor stays theirs.
- **To move or redo a part**, name the region: `pixi.transformSelection {x, y, w, h, dx, dy}`
  moves what is in it; `clear` (an op) empties it. Neither touches the person's selection.
- **When the person is mid-stroke or has a transform open**, your call answers
  `.{ .waiting = ... }` and runs the moment they let go. Look again before planning the next pass:
  they may have drawn too.
- A stroke goes through its `points` in straight lines; give a point at the end of every run of
  pixels: that is the line you mean.

### Passes that work

1. **Ground.** On a dark theme the checkerboard swallows dark inks. Fill the bottom layer with a
   light paper colour (a `fill`), then `pixi.addLayer` to draw above it, and name it in each call.
2. **Silhouette.** The outline in one mid-dark color, in a few strokes. Then read whether it
   reads.
3. **Clean the curves.** In a pixel curve the run lengths shrink steadily (6, 3, 2, 1, 1) and then
   grow (1, 2, 3); a run that breaks the order is a lump. Mirror a symmetric shape exactly. To
   redo a part, `clear` its region and draw it again.
4. **Flat colours.** A `fill` per area.
5. **Light.** Pick the light's direction first. Shadows lean cooler (toward purple), highlights
   warmer (toward orange); a ramp that only changes brightness looks muddy. Shadow hugs the form
   away from the light; a highlight runs along the edge facing it.
6. **Detail, then step back.** Add details last, then look at the whole for accidents. Three
   spots on a cap become eyes and a mouth; two shapes that just touch flatten the depth between
   them. Fix what you see.

At small sizes, watch for what a shape turns into: one-pixel teeth merge into a smudge (make
fewer, bigger ones); a boxy cap on two single-pixel legs is a little robot; two straight lines
that flare alike are a pair of trousers (flare one side lower: grown, not built). One object
overlapping another, its outline starting where it comes out from behind, is the cheapest depth
there is.

### Gaps today

- `pixi.read` gives one layer: read each layer you drew on.
- History is shared: the person's undo can take back your last pass, and yours theirs.
