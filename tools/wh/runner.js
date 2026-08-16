window.__mm={done:0,total:63,out:[],state:"running"};
window.__names=["Adjutant Galos", "Arthur Flew", "Beska Redtusk", "Bloodlord Mandokir", "Brendormi", "Caeris Fairdawn", "Collector Ta'steld", "Construct V'anore", "Dealer Vexil", "Deathguard Netharian", "Degentrius", "Derrick Brindlebeard", "Doru Thunderhorn", "Eliza Killian", "Fleshwing", "Freka Bloodaxe", "Gieger", "Gina Mudclaw", "Gormtamer Tizo", "Gottum", "Granpap Whiskers", "Gul'dan", "Harb Clawhoof", "High Priest Thekal", "Hirukon", "Historian Ma'di", "Hopecrusher", "Humon'gozz", "Irisee", "Jan'sari", "Lindormi", "Magovu", "Malbog", "Mothkeeper Wew'tam", "Naynar", "Necrolord Sipe", "Nerissa Heartless", "Ogunaro Wolfrunner", "Ponzo", "Provisioner Qorra", "Relinquishing Relics", "Rillie Spindlenut", "Rook Hawkfist", "Samamba", "Second Mate Sluggs", "Skullripper", "So'leah", "Stygian Stonecrusher", "Sylvanas Windrunner", "Tahonta", "Tattukiaka", "Telemancer Astrandis", "Thraxadus", "Trellis Morningsun", "Ula'tek", "Uncle Bigpocket", "Vasarin Redmorn", "Violet Mistake", "Void Researcher Anowin", "Warbringer Mal'Korak", "Wild Worldcracker", "Wrangler Kravos", "Zul'jan"];

(async () => {
  const norm = s => s.toLowerCase().replace(/[’]/g,"'").replace(/\s+/g,' ').trim();
  const sleep = ms => new Promise(r=>setTimeout(r,ms));
  for (const nm of window.__names) {
    const rec = { npc: nm };
    try {
      const sr = await fetch('/search/suggestions-template?q='+encodeURIComponent(nm)+'&locale=0');
      const sj = JSON.parse(await sr.text());
      const exact = (sj.results||[]).filter(r => r.type===1 && norm(r.name)===norm(nm));
      if (exact.length===0)      { rec.status='notfound'; }
      else if (exact.length>1)   { rec.status='ambiguous'; rec.ids=exact.map(e=>e.id); }
      else {
        rec.id = exact[0].id; 
        const pr = await fetch('/npc='+rec.id);
        const html = await pr.text();
        const m = html.match(/g_mapperData\s*=\s*(\{[\s\S]*?\});/);
        if (!m) { rec.status='nocoords'; }
        else {
          const md = JSON.parse(m[1]);
          const spawns = [];
          for (const k of Object.keys(md)) for (const e of md[k])
            if (e.coords && e.coords.length)
              spawns.push({ uiMapId:e.uiMapId, zone:e.uiMapName, x:e.coords[0][0], y:e.coords[0][1], n:e.coords.length });
          if (!spawns.length) rec.status='nocoords';
          else {
            const maps = [...new Set(spawns.map(s=>s.uiMapId))];
            rec.status = maps.length>1 ? 'multizone' : 'ok';
            rec.spawns = spawns.slice(0,6);
          }
        }
      }
    } catch(e) { rec.status='error'; rec.msg=String(e).slice(0,120); }
    window.__mm.out.push(rec); window.__mm.done++;
    await sleep(350);
  }
  window.__mm.state='finished';
})();
'fired'
