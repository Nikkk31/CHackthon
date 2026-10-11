import { ArrowRight, FolderOpen, PenLine, Upload } from "lucide-react";
import Link from "next/link";
import type { ReactNode } from "react";
import type { Project } from "@/types/api";

type QuickActionsProps = {
    onNewProject: () => void;
    onImport: () => void;
    lastProject: Project | null;
};

const cardClass =
    "group flex w-full items-center gap-4 rounded-card border border-line bg-surface p-4 text-left shadow-soft transition duration-200 hover:border-line-strong hover:bg-surface-muted/40";

function ActionBody({ icon, title, description }: { icon: ReactNode; title: string; description: string }) {
    return (
        <>
            <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-ctl bg-accent-soft text-accent">
                {icon}
            </span>
            <span className="min-w-0 flex-1">
                <span className="block truncate text-sm font-semibold text-ink">{title}</span>
                <span className="block truncate text-xs text-ink-faint">{description}</span>
            </span>
            <ArrowRight
                className="h-4 w-4 shrink-0 text-ink-faint transition-transform group-hover:translate-x-0.5"
                aria-hidden="true"
            />
        </>
    );
}

export function QuickActions({ onNewProject, onImport, lastProject }: QuickActionsProps) {
    return (
        <section aria-label="Quick actions" className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <button type="button" onClick={onNewProject} className={cardClass}>
                <ActionBody
                    icon={<PenLine className="h-5 w-5" aria-hidden="true" />}
                    title="Blank project"
                    description="Start with an empty canvas page"
                />
            </button>
            <button type="button" onClick={onImport} className={cardClass}>
                <ActionBody
                    icon={<Upload className="h-5 w-5" aria-hidden="true" />}
                    title="Import college notes"
                    description="PDF, PPT, DOCX or images"
                />
            </button>
            {lastProject && (
                <Link href={`/projects/${lastProject.id}`} className={cardClass}>
                    <ActionBody
                        icon={<FolderOpen className="h-5 w-5" aria-hidden="true" />}
                        title="Continue last project"
                        description={lastProject.name}
                    />
                </Link>
            )}
        </section>
    );
}