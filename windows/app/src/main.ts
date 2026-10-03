import "@fontsource-variable/inter/opsz.css";
// A summary's emphasis, which the browser would otherwise fake by slanting.
import "@fontsource-variable/inter/opsz-italic.css";
import "@fontsource-variable/jetbrains-mono";
import "./app.css";
import { mount } from "svelte";
import App from "./App.svelte";

mount(App, { target: document.getElementById("app")! });
