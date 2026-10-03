import "./app.css";
import { mount } from "svelte";
import Hud from "./Hud.svelte";

mount(Hud, { target: document.getElementById("hud")! });
