export const BLUE = "#0972d3";
export const ORANGE = "#eb5f07";
export const GREEN = "#037f0c";

export function Node({
  x,
  y,
  w,
  h,
  title,
  sub,
  stroke = BLUE,
}: {
  x: number;
  y: number;
  w: number;
  h: number;
  title: string;
  sub?: string;
  stroke?: string;
}) {
  return (
    <g>
      <rect
        x={x}
        y={y}
        width={w}
        height={h}
        rx={8}
        fill="#ffffff"
        stroke={stroke}
        strokeWidth={2}
      />
      <text
        x={x + w / 2}
        y={sub ? y + h / 2 - 4 : y + h / 2 + 4}
        textAnchor="middle"
        fontSize="14"
        fontWeight="700"
        fill="#0f1b2d"
      >
        {title}
      </text>
      {sub && (
        <text
          x={x + w / 2}
          y={y + h / 2 + 14}
          textAnchor="middle"
          fontSize="11"
          fill="#5f6b7a"
        >
          {sub}
        </text>
      )}
    </g>
  );
}
