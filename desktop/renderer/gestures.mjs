export const QUICK_PRESS_SECONDS = 0.25;

/** Buffer quick taps until a quiet interval proves the streak had exactly two. */
export class ClickSequence {
  constructor(interval = 0.5, grace = 0.03) {
    this.interval = interval;
    this.grace = grace;
    this.streak = 0;
    this.lastAt = null;
    this.active = false;
    this.suppressed = false;
    this.pending = [];
    this.deadline = null;
    this.wheelPoint = null;
  }
  drain() {
    const actions = this.pending.map((launch) => ({
      type: "launch",
      ...launch,
    }));
    this.pending = [];
    this.deadline = null;
    this.wheelPoint = null;
    return actions;
  }
  settle() {
    if (this.pending.length === 2 && this.streak === 2 && !this.suppressed) {
      const origin = this.wheelPoint;
      this.drain();
      return [{ type: "wheel", origin }];
    }
    return this.drain();
  }
  begin(time, point, clickCount = 0) {
    let actions = [];
    const elapsed = this.lastAt === null ? Infinity : time - this.lastAt;
    const far =
      this.lastPoint &&
      Math.hypot(point.x - this.lastPoint.x, point.y - this.lastPoint.y) > 6;
    if (
      elapsed > this.interval + this.grace &&
      !(clickCount >= 2 && this.streak > 0)
    ) {
      actions = this.settle();
      this.streak = 0;
      this.suppressed = false;
    }
    this.lastAt = time;
    this.streak++;
    this.active = true;
    if (
      (clickCount > 0 && clickCount !== this.streak) ||
      (far && this.streak > 1) ||
      this.streak >= 3
    )
      this.suppressed = true;
    this.lastPoint = point;
    if (this.suppressed) actions.push(...this.drain());
    return actions;
  }
  end(time, origin, duration, valid = true) {
    if (!this.active) return [];
    this.active = false;
    this.lastAt = time;
    if (!valid) {
      this.suppressed = true;
      return this.drain();
    }
    const launch = { origin, duration };
    if (duration >= QUICK_PRESS_SECONDS || this.suppressed || this.streak > 2) {
      this.suppressed = true;
      return [...this.drain(), { type: "launch", ...launch }];
    }
    this.pending.push(launch);
    this.wheelPoint = this.streak === 2 ? origin : null;
    this.deadline = time + this.interval + this.grace;
    return [];
  }
  interrupt(time) {
    const actions = this.drain();
    if (
      this.lastAt !== null &&
      time - this.lastAt <= this.interval + this.grace
    )
      this.suppressed = true;
    else {
      this.streak = 0;
      this.suppressed = false;
    }
    this.lastAt = time;
    this.active = false;
    return actions;
  }
  resolve(time) {
    return this.deadline !== null && time >= this.deadline && !this.active
      ? this.settle()
      : [];
  }
}
