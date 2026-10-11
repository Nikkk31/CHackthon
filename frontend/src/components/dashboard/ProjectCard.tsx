"use client";

import { Pencil, Trash2 } from "lucide-react";
import Link from "next/link";
import { Menu } from "@/components/ui/Menu";
import { cn, formatRelative } from "@/lib/utils";
import type { Project } from "@/types/api";

const COVERS = ["bg-[#efecfb]", "bg-[#f1f0f6]", "bg-[#ece9f8]", "bg-[#f4f1fa]", "bg-[#e9e8f3]"];

type ProjectCardProps = {
    project: Project;
    onRename: (project: Project) => void;
    onDelete: (project: Project) => void;
};

export function ProjectCard({ project, onRename, onDelete }: ProjectCardProps) {
    const pages = `${project.page_count} ${project.page_count === 1 ? "page" : "pages"}`;

    return (
        <article className="anim-fade group relative rounded-card border border-line bg-surface shadow-soft transition duration-200 hover:-translate-y-0.5 hover:border-line-strong">
            <Link
                href={`/projects/${project.id}`}
                className="absolute inset-0 z-0 rounded-card"
                aria-label={`Open ${project.name}`}
            />

            <div
                className={cn(
                    "pointer-events-none relative h-32 overflow-hidden rounded-t-card",
                    COVERS[Math.abs(project.id) % COVERS.length],
                )}
                aria-hidden="true"
            >
                <div className="absolute inset-x-6 bottom-0 top-5 rounded-t-lg border border-line bg-surface/90 p-3 shadow-sm">
                    <div className="h-1.5 w-1/2 rounded-full bg-accent/25" />
                    <div className="mt-2 h-1.5 w-4/5 rounded-full bg-line" />
                    <div className="mt-2 h-1.5 w-3/5 rounded-full bg-line" />
                </div>
            </div>

            <div className="flex items-start justify-between gap-2 p-4">
                <div className="min-w-0">
                    <h3 className="truncate text-sm font-semibold text-ink">{project.name}</h3>
                    <p className="mt-1 truncate text-xs text-ink-faint">
                        {pages} · Edited {formatRelative(project.updated_at)}
                    </p>
                </div>
                <Menu
                    className="relative z-10"
                    label={`Options for ${project.name}`}
                    items={[
                        { label: "Rename", icon: <Pencil className="h-4 w-4" />, onSelect: () => onRename(project) },
                        { label: "Delete", icon: <Trash2 className="h-4 w-4" />, onSelect: () => onDelete(project), danger: true },
                    ]}
                />
            </div>
        </article>
    );
}