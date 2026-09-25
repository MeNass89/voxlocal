// The waveform glyph from the Mac app (sidebar logo and "Dictées" section),
// drawn as hairline SVG outlines to match the page's line work. Used for the
// large faint marks; the header and footer use the app icon PNG.
const bars = [
  [2, 9, 6],
  [6, 5, 14],
  [10, 1, 22],
  [14, 6, 12],
  [18, 3, 18],
  [22, 8, 8],
];

export function WaveGlyph({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {bars.map(([x, y, h]) => (
        <rect key={x} x={x - 0.9} y={y} width={1.8} height={h} rx={0.9} fill="none" stroke="currentColor" strokeWidth={0.12} />
      ))}
    </svg>
  );
}
