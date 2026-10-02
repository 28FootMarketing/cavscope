// Flesch-Kincaid grade level, dependency-free. Pure so tests can import it.
// Syllables are estimated by vowel groups; good to about a half grade on plain English,
// which is the precision a ratchet needs, not a certification.

export function countSyllables(word) {
  let w = word.toLowerCase().replace(/[^a-z]/g, "");
  if (!w) return 0;
  if (w.length <= 3) return 1;
  w = w.replace(/(?:[^laeiouy]es|ed|[^laeiouy]e)$/, "").replace(/^y/, "");
  const groups = w.match(/[aeiouy]{1,2}/g);
  return Math.max(1, groups ? groups.length : 1);
}

export function stats(text) {
  const clean = text.replace(/\s+/g, " ").trim();
  const sentences = clean.split(/(?<=[.!?])\s+|(?<=:)\s+(?=[A-Z])/).filter((s) => /[a-z]/i.test(s));
  const words = clean.match(/[A-Za-z][A-Za-z'’-]*/g) || [];
  const syllables = words.reduce((n, w) => n + countSyllables(w), 0);
  return { sentences: Math.max(1, sentences.length), words: words.length, syllables };
}

export function grade(text) {
  const s = stats(text);
  if (s.words === 0) return 0;
  return 0.39 * (s.words / s.sentences) + 11.8 * (s.syllables / s.words) - 15.59;
}

// Grade a set of strings as one body of text, so a list of short tooltips is judged
// by the copy a reader meets overall, not by how a single fragment scores.
export function gradeAll(strings) {
  return grade(strings.map((t) => (/[.!?]$/.test(t.trim()) ? t.trim() : t.trim() + ".")).join(" "));
}
