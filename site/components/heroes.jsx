// Hero — Color Pop (centered + 4-color accents). Canonical, only variant.
// Shared bits: VersionChipColor (live), ColorDots, Kbd, WG_COLORS.

const { useEffect: useEffectHero, useState: useStateHero } = React;

// MS flag colors (from the logo)
const WG_COLORS = {
  red:    '#F25022',
  green:  '#7FBA00',
  blue:   '#00A4EF',
  yellow: '#FFB900',
};

// --- Live version hook ---
function useLiveVersion() {
  const initial = (typeof window !== 'undefined' && window.WG_VERSION) || '1.3.106';
  const [v, setV] = useStateHero(initial);
  useEffectHero(() => {
    const onUpdate = (e) => {
      const newV = e?.detail?.version || (window.WG_VERSION || initial);
      setV(newV);
    };
    window.addEventListener('wg-version-updated', onUpdate);
    if (window.WG_VERSION && window.WG_VERSION !== initial) setV(window.WG_VERSION);
    return () => window.removeEventListener('wg-version-updated', onUpdate);
  }, []);
  return v;
}

function ColorDots({ size = 8, gap = 6 }) {
  const cs = [WG_COLORS.red, WG_COLORS.green, WG_COLORS.blue, WG_COLORS.yellow];
  return (
    <span style={{ display: 'inline-flex', gap, alignItems: 'center' }}>
      {cs.map((c) => (
        <span key={c} style={{
          width: size, height: size, borderRadius: 2, background: c,
          display: 'inline-block',
        }} />
      ))}
    </span>
  );
}

function VersionChipColor({ theme, meta }) {
  const v = useLiveVersion();
  const C = theme === 'dark'
    ? { bg: '#101012', border: '#26262a', fg: '#c4c4c8', dim: '#707078', sep: '#2e2e34' }
    : { bg: '#ffffff', border: '#d8d8d6', fg: '#3a3a38', dim: '#7a7a78', sep: '#dcdcda' };
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 10,
      padding: '6px 14px 6px 10px', borderRadius: 999,
      background: C.bg, border: `1px solid ${C.border}`,
      fontFamily: 'var(--mono)', fontSize: 11, color: C.fg,
      letterSpacing: '0.04em',
    }}>
      <ColorDots size={7} gap={4} />
      <span>{`v${v} · latest release`}</span>
      {meta && (
        <>
          <span style={{ width: 1, height: 12, background: C.sep, display: 'inline-block' }} />
          <span style={{ color: C.dim }}>{meta}</span>
        </>
      )}
    </span>
  );
}

function Kbd({ children, theme }) {
  const C = theme === 'dark'
    ? { bg: '#1c1c20', fg: '#d4d4d8', border: '#2e2e34' }
    : { bg: '#f3f3f1', fg: '#1a1a1a', border: '#d8d8d6' };
  return (
    <span style={{
      display: 'inline-block', padding: '2px 8px', borderRadius: 4,
      background: C.bg, color: C.fg, border: `1px solid ${C.border}`,
      fontFamily: 'var(--mono)', fontSize: 11, lineHeight: 1.4,
    }}>{children}</span>
  );
}

// =========================================================
// HERO — Color Pop (canonical)
// =========================================================
function HeroColorPop({ theme }) {
  const C = theme === 'dark'
    ? { fg: '#e5e5e5', dim: '#8a8a92', rule: '#1e1e22' }
    : { fg: '#0a0a0a', dim: '#4a4a48', rule: '#d8d8d6' };

  const glowBg = theme === 'dark'
    ? `radial-gradient(ellipse 60% 50% at 15% 30%, ${WG_COLORS.red}22, transparent 60%),
       radial-gradient(ellipse 50% 40% at 85% 25%, ${WG_COLORS.green}1f, transparent 60%),
       radial-gradient(ellipse 55% 45% at 20% 80%, ${WG_COLORS.blue}22, transparent 60%),
       radial-gradient(ellipse 50% 45% at 85% 80%, ${WG_COLORS.yellow}1e, transparent 60%)`
    : `radial-gradient(ellipse 60% 50% at 15% 30%, ${WG_COLORS.red}14, transparent 60%),
       radial-gradient(ellipse 50% 40% at 85% 25%, ${WG_COLORS.green}12, transparent 60%),
       radial-gradient(ellipse 55% 45% at 20% 80%, ${WG_COLORS.blue}14, transparent 60%),
       radial-gradient(ellipse 50% 45% at 85% 80%, ${WG_COLORS.yellow}12, transparent 60%)`;

  return (
    <section style={{ padding: '8px 0 0', textAlign: 'center' }}>
      <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 22 }}>
        <VersionChipColor theme={theme} meta="MIT · Windows 10 / 11 · x64" />
      </div>

      <h1 style={{
        fontSize: 'clamp(56px, 9vw, 132px)', lineHeight: 0.95, letterSpacing: '-0.045em',
        fontWeight: 500, color: C.fg, margin: '0 auto 26px', maxWidth: 1100,
      }}>
        Ghostty<span style={{ color: WG_COLORS.red }}>,</span> finally<br />
        on Windows<span style={{ color: WG_COLORS.blue }}>.</span>
      </h1>

      <p style={{
        color: C.dim, fontSize: 18, lineHeight: 1.5, maxWidth: 540, margin: '0 auto 28px', textWrap: 'pretty',
      }}>
        The Ghostty you know and love, now on Windows. Winghostty is a Windows-native fork that brings Ghostty's terminal core into a real Windows app, with tabs, splits, profiles, and plain-text configuration.
      </p>

      <div style={{ display: 'flex', gap: 10, justifyContent: 'center', flexWrap: 'wrap', marginBottom: 40, alignItems: 'center' }}>
        <InstallBlock theme={theme} />
        <a href="https://github.com/amanthanvi/winghostty/releases/latest" target="_blank" rel="noreferrer"
          style={{
            height: 46, padding: '0 18px', borderRadius: 10, textDecoration: 'none',
            color: C.fg, border: `1px solid ${C.rule}`, fontSize: 14,
            display: 'inline-flex', alignItems: 'center', gap: 8,
            fontFamily: 'var(--mono)', boxSizing: 'border-box',
            transition: 'opacity 0.15s',
          }}
          onMouseEnter={(e) => (e.currentTarget.style.opacity = '0.7')}
          onMouseLeave={(e) => (e.currentTarget.style.opacity = '1')}
        >
          Download ↗
        </a>
      </div>

      <div style={{ position: 'relative', maxWidth: 1000, margin: '0 auto' }}>
        <div aria-hidden="true" style={{
          position: 'absolute', inset: '-80px -40px', background: glowBg,
          filter: 'blur(24px)', pointerEvents: 'none', zIndex: 0,
        }} />
        <div style={{ position: 'relative', zIndex: 1 }}>
          <WinghosttyTerminal theme={theme} height={420} autoplay={false} />
        </div>
      </div>
    </section>
  );
}

Object.assign(window, {
  HeroColorPop, VersionChipColor, ColorDots, Kbd, WG_COLORS,
});
