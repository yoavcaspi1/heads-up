import React from "react";
import ReactDOM from "react-dom/client";
import { TooltipProvider } from "@glaze/core/components";
import { initLogging } from "@glaze/core/utils";
import { AlertView } from "./alert-view";
import "../styles.css";

initLogging();

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Root element not found");
}

const root = ReactDOM.createRoot(rootElement);
root.render(
  <React.StrictMode>
    <TooltipProvider>
      <AlertView />
    </TooltipProvider>
  </React.StrictMode>,
);

if (import.meta.hot) {
  import.meta.hot.accept();
}
