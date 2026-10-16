# pixi, for an agent

What an agent needs to know to work in pixi well. People read it in the plugin store; an agent gets
it from the command `pixi.guide`, first in its index of commands. Read it before drawing.

## Drawing

Drawing is not generating. A picture rendered somewhere else and brought in whole had every
decision made before the first pixel landed. To draw, make marks with `pixi.draw`, look at what
they did, and decide the next mark from what you saw. The picture comes out of the passes.

### The rules

- **Strokes, not rows.** Draw with `pixi.draw`'s `stroke`, `line`, `fill`, `rect`, `ellipse` and
  `clear` ops: marks made with a pen, a bucket, an eraser. Don't render a picture elsewhere (a
  script, a raytracer) and bring it in: that is generating, not drawing. `pixi.stamp` puts back
  pixels you already have from `pixi.read`, such as a frame copied to the next cell, and nothing
  else.
- **Look between passes.** After each pass, look twice: `fizzy_capture` with the canvas for the
  whole impression, and `pixi.read` for exact pixels. The image shows whether it reads; the grid
  shows where it is wrong.
- **Plan after looking.** Write each pass's plan after the look before it, and name what it fixes:
  "the cap's runs go 3, 2, 1, 1, 2: make them 3, 2, 1, 1 then 2, 6". A plan written before you
  looked is a traced picture.

### `pixi.draw`'s ops

One call is a list of steps, each a one-field struct naming its kind, drawn in order onto one layer
as one undo step. Colours are `#rrggbb`, `#rrggbbaa` or `none` (erase). Coordinates are pixels from
the sprite's top left, across the whole sheet; what falls outside is skipped.

- `stroke`: `.{ .points = .{ .{ x, y }, ... }, .color, .size = 1, .square = false }`. The pencil
  through the points in straight lines, with a round (or square) brush `size` across. `none` erases.
- `line`: `.{ .x1, .y1, .x2, .y2, .color }`. One pixel wide.
- `fill`: `.{ .x, .y, .color, .contiguous = true }`. The bucket; `contiguous = false` fills every
  pixel of that colour.
- `rect`: `.{ .x, .y, .w, .h, .color, .filled = true }`.
- `ellipse`: `.{ .x, .y, .w, .h, .color, .filled = true }`. An ellipse inside an outline drawn
  with one is not inside it pixel for pixel: draw the outline after the fill, or as a stroke.
- `clear`: `.{ .x, .y, .w, .h }`. Transparent; `w`/`h` 0 reach the edge.

`pixi.read` answers a region as text rows and a legend: `.` transparent, every other character a
colour the legend names. Read with `layer = "*"` to see every visible layer together.

### A sprite sheet and its animation

1. `pixi.create` with `width`/`height` (one cell) and `columns`/`rows`, and a `path` if it should
   be saved. It opens the sprite and answers its path (an untitled one's too): give that `path` to
   every call after.
2. Cell `i` is at `x = (i % columns) * width`, `y = (i / columns) * height`. Draw each frame in its
   cell, in passes, looking between them (below).
3. `pixi.createAnimation` with `frames = .{ .{ .cell = 0, .ms = 100 }, ... }`, then
   `pixi.playAnimation`.

**Always give `path`.** A command given none acts on the active sprite, which may be one the
person is working on, not yours. Only when no sprite is active at all (the person is in a chat)
does it fall back to the sprite the last command made or acted on.

`fizzy_commands` with a prefix (`"pixi."`, or a whole id) lists commands with their parameters.

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
