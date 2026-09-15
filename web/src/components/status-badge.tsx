import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

export type Tone = "success" | "warning" | "destructive" | "neutral";

const dot: Record<Tone, string> = {
  success: "bg-success",
  warning: "bg-warning",
  destructive: "bg-destructive",
  neutral: "bg-muted-foreground",
};

const text: Record<Tone, string> = {
  success: "text-success",
  warning: "text-warning",
  destructive: "text-destructive",
  neutral: "text-muted-foreground",
};

/** Outline pill with a colored dot. The label always says the state, so color is never the only cue. */
export function StatusBadge({ tone, children, mono, className }: {
  tone: Tone;
  children: React.ReactNode;
  mono?: boolean;
  className?: string;
}) {
  return (
    <Badge variant="outline" className={cn("h-6 gap-1.5 bg-card px-2.5", text[tone], mono && "num", className)}>
      <span aria-hidden className={cn("size-1.5 rounded-full", dot[tone])} />
      {children}
    </Badge>
  );
}
