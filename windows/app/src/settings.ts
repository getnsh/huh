import "@fontsource-variable/inter/opsz.css";
import "@fontsource-variable/jetbrains-mono";
import "./app.css";
import { mount } from "svelte";
import Settings from "./settings/Settings.svelte";

mount(Settings, { target: document.getElementById("settings")! });
