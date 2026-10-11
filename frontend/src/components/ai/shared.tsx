"use client";
import { ButtonHTMLAttributes } from "react";

export function Btn({
  variant = "primary", className = "", ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "ghost" | "danger" }) {
  const styles = {
    primary: "bg-neutral-900 text-white hover:bg-neutral-700",
    ghost: "border border-neutral-300 text-neutral-800 hover:bg-neutral-100",
    danger: "border border-red-300 text-red-700 hover:bg-red-50",
  }[variant];
  return (
    <button
      {...props}
      className={`rounded-md px-3 py-1.5 text-sm font-medium transition-colors disabled:opacity-50 disabled:cursor-not-allowed ${styles} ${className}`}
    />
  );
}

export function Loading({ label = "Thinking..." }: { label?: string }) {
  return (
    <div className="flex items-center gap-2 text-sm text-neutral-500 py-3" role="status">
      <span className="h-4 w-4 animate-spin rounded-full border-2 border-neutral-300 border-t-neutral-700" />
      {label} <span className="text-xs">(can take up to 30 s)</span>
    </div>
  );
}

export function ErrorBox({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
      <p>{message}</p>
      {onRetry && (
        <button onClick={onRetry} className="mt-1 underline">Try again</button>
      )}
    </div>
  );
}

export const errMsg = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong");

export function Sources({ sources }: { sources: { page_id: number; title: string }[] }) {
  if (!sources?.length) return null;
  return (
    <div className="mt-2 flex flex-wrap gap-1.5">
      {sources.map((s) => (
        <span key={s.page_id} className="rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-600">
          {s.title || `Page ${s.page_id}`}
        </span>
      ))}
    </div>
  );
}

export const NotGrounded = () => (
  <span className="inline-block rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800">
    Not found in your notes
  </span>
);
