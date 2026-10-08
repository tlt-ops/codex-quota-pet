export async function loadImage(url) {
  const image = new Image();
  image.src = url;
  await image.decode();
  return image;
}

/** Only remove near-white pixels reachable from an image edge. */
export function removeEdgeWhite(imageData) {
  const { width, height, data } = imageData;
  const total = width * height,
    visited = new Uint8Array(total),
    queue = new Int32Array(total);
  let head = 0,
    tail = 0;
  const push = (index) => {
    if (visited[index]) return;
    const offset = index * 4,
      r = data[offset],
      g = data[offset + 1],
      b = data[offset + 2];
    if (Math.min(r, g, b) < 245 || Math.max(r, g, b) - Math.min(r, g, b) > 12)
      return;
    visited[index] = 1;
    queue[tail++] = index;
  };
  for (let x = 0; x < width; x++) {
    push(x);
    push((height - 1) * width + x);
  }
  for (let y = 0; y < height; y++) {
    push(y * width);
    push(y * width + width - 1);
  }
  while (head < tail) {
    const index = queue[head++],
      x = index % width,
      y = Math.floor(index / width);
    if (x) push(index - 1);
    if (x + 1 < width) push(index + 1);
    if (y) push(index - width);
    if (y + 1 < height) push(index + width);
    data.fill(0, index * 4, index * 4 + 4);
  }
  return imageData;
}

export async function loadSprites(url) {
  const source = await loadImage(url),
    sprites = [];
  for (let row = 0; row < 4; row++)
    for (let column = 0; column < 6; column++) {
      const x0 = Math.round((column * source.width) / 6),
        x1 = Math.round(((column + 1) * source.width) / 6);
      const y0 = Math.round((row * source.height) / 4),
        y1 = Math.round(((row + 1) * source.height) / 4);
      const canvas = document.createElement("canvas");
      canvas.width = x1 - x0;
      canvas.height = y1 - y0;
      const context = canvas.getContext("2d", { willReadFrequently: true });
      context.drawImage(
        source,
        x0,
        y0,
        canvas.width,
        canvas.height,
        0,
        0,
        canvas.width,
        canvas.height,
      );
      context.putImageData(
        removeEdgeWhite(
          context.getImageData(0, 0, canvas.width, canvas.height),
        ),
        0,
        0,
      );
      sprites.push(canvas);
    }
  return sprites;
}
