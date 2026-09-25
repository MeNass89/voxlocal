"use client";

import { useEffect, useRef } from "react";

type Point = { x: number; y: number; z: number };

export function ImmersiveScene() {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const context = canvas.getContext("2d");
    if (!context) return;

    let frame = 0;
    let width = 0;
    let height = 0;
    let pixelRatio = 1;
    let pointerX = 0;
    let pointerY = 0;
    let scroll = window.scrollY;
    let animationFrame = 0;
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    const resize = () => {
      pixelRatio = Math.min(window.devicePixelRatio || 1, 2);
      width = window.innerWidth;
      height = window.innerHeight;
      canvas.width = width * pixelRatio;
      canvas.height = height * pixelRatio;
      canvas.style.width = `${width}px`;
      canvas.style.height = `${height}px`;
      context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
    };

    const onPointerMove = (event: PointerEvent) => {
      pointerX = event.clientX / width - 0.5;
      pointerY = event.clientY / height - 0.5;
    };

    const onScroll = () => { scroll = window.scrollY; };

    const rotate = (point: Point, ax: number, ay: number, az: number): Point => {
      let { x, y, z } = point;
      const cX = Math.cos(ax), sX = Math.sin(ax);
      [y, z] = [y * cX - z * sX, y * sX + z * cX];
      const cY = Math.cos(ay), sY = Math.sin(ay);
      [x, z] = [x * cY + z * sY, -x * sY + z * cY];
      const cZ = Math.cos(az), sZ = Math.sin(az);
      [x, y] = [x * cZ - y * sZ, x * sZ + y * cZ];
      return { x, y, z };
    };

    const draw = () => {
      context.clearRect(0, 0, width, height);
      const time = reducedMotion ? 1.8 : frame * 0.006;
      const scrollShift = Math.min(scroll / Math.max(height, 1), 6);

      const gradient = context.createRadialGradient(
        width * (0.63 + pointerX * 0.04), height * (0.43 + pointerY * 0.04), 0,
        width * 0.58, height * 0.45, Math.max(width, height) * 0.7,
      );
      gradient.addColorStop(0, "rgba(118, 154, 183, 0.085)");
      gradient.addColorStop(0.35, "rgba(28, 37, 45, 0.05)");
      gradient.addColorStop(1, "rgba(0, 0, 0, 0)");
      context.fillStyle = gradient;
      context.fillRect(0, 0, width, height);

      context.save();
      context.globalCompositeOperation = "screen";
      const heroFade = Math.max(0.12, 1 - scroll / (height * 1.45));
      const size = Math.min(width, height) * (width < 760 ? 0.24 : 0.32);
      const centerX = width * (width < 760 ? 0.69 : 0.67) + pointerX * 24;
      const centerY = height * 0.47 + pointerY * 18 - scrollShift * 18;
      const segments = 260;
      let previous: { x: number; y: number; z: number } | null = null;

      for (let index = 0; index <= segments; index += 1) {
        const angle = (index / segments) * Math.PI * 2;
        const point = rotate(
          {
            x: Math.sin(angle) * 1.15,
            y: Math.sin(angle) * Math.cos(angle) * 1.72,
            z: Math.cos(angle * 2) * 0.24 + Math.sin(angle * 5 + time) * 0.035,
          },
          -0.08 + pointerY * 0.15,
          0.22 + pointerX * 0.2,
          -0.08 + Math.sin(time * 0.35) * 0.05,
        );
        const perspective = 1 / (2.8 - point.z * 0.32);
        const projected = {
          x: centerX + point.x * size * perspective * 1.5,
          y: centerY + point.y * size * perspective * 1.5,
          z: point.z,
        };

        if (previous) {
          const depth = Math.max(0.2, Math.min(1, (projected.z + 1.3) / 2.4));
          context.beginPath();
          context.moveTo(previous.x, previous.y);
          context.lineTo(projected.x, projected.y);
          context.strokeStyle = `rgba(221, 239, 248, ${heroFade * (0.28 + depth * 0.62)})`;
          context.shadowColor = "rgba(189, 228, 245, .85)";
          context.shadowBlur = 8 + depth * 11;
          context.lineWidth = 1.1 + depth * 1.2;
          context.stroke();
        }
        previous = projected;
      }

      for (let index = 0; index < 54; index += 1) {
        const seed = (index * 47.13) % 101;
        const x = ((seed / 101 + time * (0.0015 + (index % 5) * 0.00035)) % 1) * (width + 160) - 80;
        const y = ((index * 83.7 + (reducedMotion ? 0 : frame * (0.08 + (index % 7) * 0.025))) % (height + 260)) - 130;
        const length = 20 + (index % 9) * 9;
        const alpha = (0.08 + (index % 6) * 0.025) * heroFade;
        context.beginPath();
        context.moveTo(x, y);
        context.lineTo(x - length * 0.34, y + length);
        context.strokeStyle = `rgba(203, 228, 238, ${alpha})`;
        context.shadowBlur = 3;
        context.lineWidth = index % 8 === 0 ? 1.2 : 0.55;
        context.stroke();
      }

      context.restore();
      frame += 1;
      if (!reducedMotion) animationFrame = requestAnimationFrame(draw);
    };

    resize();
    draw();
    window.addEventListener("resize", resize);
    window.addEventListener("pointermove", onPointerMove, { passive: true });
    window.addEventListener("scroll", onScroll, { passive: true });

    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) entry.target.classList.add("is-visible");
      }
    }, { threshold: 0.12 });
    document.querySelectorAll(".reveal").forEach((element) => observer.observe(element));

    return () => {
      cancelAnimationFrame(animationFrame);
      observer.disconnect();
      window.removeEventListener("resize", resize);
      window.removeEventListener("pointermove", onPointerMove);
      window.removeEventListener("scroll", onScroll);
    };
  }, []);

  return <canvas ref={canvasRef} className="immersive-scene" aria-hidden="true" />;
}
