import { saveHikes } from "./save";

export function renderList(hikes: string[]): string {
  saveHikes(hikes);
  return hikes.join(", ");
}
