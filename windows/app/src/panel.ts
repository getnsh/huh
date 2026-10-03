import "@fontsource-variable/inter/opsz.css";
import "@fontsource-variable/jetbrains-mono";
import "./app.css";
import { mount } from "svelte";
import Panel from "./panel/Panel.svelte";

mount(Panel, { target: document.getElementById("panel")! });
