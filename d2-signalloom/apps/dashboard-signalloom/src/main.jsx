import React from "react";
import { createRoot } from "react-dom/client";

const App = () => (
  <main>
    <h1>Signal Loom</h1>
    <p>Local dashboard workload is ready.</p>
  </main>
);

createRoot(document.getElementById("root")).render(<App />);
