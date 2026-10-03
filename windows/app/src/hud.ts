import "@fontsource-variable/inter/opsz.css";
import "@fontsource-variable/jetbrains-mono";
import "./app.css";
import { mount } from "svelte";
import Hud from "./Hud.svelte";

mount(Hud, { target: document.getElementById("hud")! });
