let counter_1 = 0;
let counter_2 = 0;

export function reset() {
  counter_1 = 0;
  counter_2 = 0;
}

export function incrementAndGetCounter(level: number): string {
  let to_return = "";

  if (level === 1) {
    counter_1 += 1;
    to_return = counter_1.toString();
  } else {
    counter_2 += 1;
    to_return = counter_1.toString() + "." + counter_2.toString();
  }

  return to_return;
}
