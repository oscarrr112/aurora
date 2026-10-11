// 地磁纬度（偏心偶极子近似）和「需要多大的 Kp 才能看到」的估算
import { RAD } from './util.js';

// IGRF 约 2025 年的前 8 个高斯系数（nT）
const g10 = -29350.0, g11 = -1410.3, h11 = 4545.5;
const g20 = -2556.2, g21 = 2950.9, h21 = -3133.6;
const g22 = 1648.7, h22 = -814.2;

/** 偶极子北极方向（单位向量）和偶极子中心相对地心的偏移（地球半径为单位） */
const dipole = (() => {
  const b0Squared = g10 * g10 + g11 * g11 + h11 * h11;
  const b0 = Math.sqrt(b0Squared);
  const s3 = Math.sqrt(3);
  const l0 = 2 * g10 * g20 + s3 * (g11 * g21 + h11 * h21);
  const l1 = -g11 * g20 + s3 * (g10 * g21 + g11 * g22 + h11 * h22);
  const l2 = -h11 * g20 + s3 * (g10 * h21 - h11 * g22 + g11 * h22);
  const e = (l0 * g10 + l1 * g11 + l2 * h11) / (4 * b0Squared);
  const xi = (l0 - g10 * e) / (3 * b0Squared);
  const eta = (l1 - g11 * e) / (3 * b0Squared);
  const zeta = (l2 - h11 * e) / (3 * b0Squared);
  return { pole: [-g11 / b0, -h11 / b0, -g10 / b0], offset: [eta, zeta, xi] };
})();

/** 地磁纬度（度），南半球为负 */
export function magneticLatitude(lat, lon) {
  const phi = lat * RAD, lambda = lon * RAD;
  const p = [
    Math.cos(phi) * Math.cos(lambda) - dipole.offset[0],
    Math.cos(phi) * Math.sin(lambda) - dipole.offset[1],
    Math.sin(phi) - dipole.offset[2],
  ];
  const length = Math.hypot(...p);
  const sinLat = (p[0] * dipole.pole[0] + p[1] * dipole.pole[1] + p[2] * dipole.pole[2]) / length;
  return Math.asin(Math.min(Math.max(sinLat, -1), 1)) / RAD;
}

/** 极光出现的方向：朝向本半球地磁极的方位角（度，正北为 0） */
export function auroraBearing(lat, lon) {
  const [x, y, z] = dipole.pole;
  let poleLat = Math.asin(z) / RAD;
  let poleLon = Math.atan2(y, x) / RAD;
  if (lat < 0) {
    poleLat = -poleLat;
    poleLon += 180;
  }
  const phi1 = lat * RAD, phi2 = poleLat * RAD;
  const dLon = (poleLon - lon) * RAD;
  const by = Math.sin(dLon) * Math.cos(phi2);
  const bx = Math.cos(phi1) * Math.sin(phi2) - Math.sin(phi1) * Math.cos(phi2) * Math.cos(dLon);
  return (Math.atan2(by, bx) / RAD + 360) % 360;
}

/** 极光卵南缘大约在磁纬 66.5° − 2.05×Kp；在地平线上能看到的范围再往低纬约 4.5° */
export function kpNeeded(magLat) {
  const m = Math.abs(magLat);
  return { overhead: (66.5 - m) / 2.05, horizon: (62.0 - m) / 2.05 };
}
