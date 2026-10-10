"use client";

import { useEffect, useState } from "react";
import { api } from "@/lib/api";

type Item = { id: number; title: string; description?: string | null };

export default function Home() {
  const [items, setItems] = useState<Item[]>([]);
  const [title, setTitle] = useState("");
  const [status, setStatus] = useState("checking...");

  const load = () => api<Item[]>("/items").then(setItems).catch(() => {});

  useEffect(() => {
    api<{ status: string }>("/health")
      .then((r) => setStatus(r.status))
      .catch(() => setStatus("backend unreachable"));
    load();
  }, []);

  async function add(e: React.FormEvent) {
    e.preventDefault();
    if (!title.trim()) return;
    await api("/items", { method: "POST", body: JSON.stringify({ title }) });
    setTitle("");
    load();
  }

  async function remove(id: number) {
    await api(`/items/${id}`, { method: "DELETE" });
    load();
  }

  return (
    <main className="mx-auto max-w-xl p-8">
      <h1 className="text-2xl font-bold">Hackathon Starter</h1>
      <p className="mb-6 text-sm text-gray-500">API status: {status}</p>

      <form onSubmit={add} className="mb-4 flex gap-2">
        <input
          className="flex-1 rounded border px-3 py-2"
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          placeholder="New item"
        />
        <button className="rounded bg-black px-4 py-2 text-white">Add</button>
      </form>

      <ul className="space-y-2">
        {items.map((i) => (
          <li key={i.id} className="flex justify-between rounded border p-3">
            {i.title}
            <button onClick={() => remove(i.id)} className="text-red-500">
              delete
            </button>
          </li>
        ))}
      </ul>
    </main>
  );
}
