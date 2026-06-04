import java.time.DayOfWeek;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.time.temporal.ChronoUnit;
import java.time.temporal.TemporalAdjusters;
 
/**
 * Grafana 의 시간 범위(from / to)에 들어가는 값을 파싱하는 파서.
 *
 * 지원 형식
 *  1) 상대 시간(date math) : "now", "now-5m", "now-1h", "now-1d/d",
 *                            "now/w", "now+12h", "now-1y/fy" 등
 *  2) Epoch milliseconds    : "1609459200000"
 *  3) ISO-8601 절대 시각    : "2021-01-01T00:00:00Z", "2021-01-01T09:00:00+09:00",
 *                            "2021-01-01 09:00:00", "2021-01-01"
 *  4) 절대시각 + date math  : "2021-01-01T00:00:00Z||+1d/d"
 *
 * Grafana 의 datemath.ts 구현을 그대로 옮긴 것입니다.
 * 지원 단위: y(년) M(월) w(주) d(일) h(시) m(분) s(초) Q(분기), 그리고 fy/fQ(회계연도/회계분기)
 *
 * 연산자
 *   +  : 더하기 (now+1d)
 *   -  : 빼기   (now-1d)
 *   /  : 해당 단위로 스냅(반올림). roundUp=false 면 단위의 시작, true 면 단위의 끝.
 *
 * 관례상 from 은 roundUp=false, to 는 roundUp=true 로 호출합니다.
 */
public class GrafanaTimeParser {
 
    /** 주의 시작 요일. moment.js 의 로케일에 해당. Grafana 설정에 맞춰 바꾸세요. */
    private DayOfWeek weekStart = DayOfWeek.MONDAY;
 
    /** 회계연도 시작 월(1=1월). Grafana 의 fiscalYearStartMonth 에 해당. */
    private int fiscalYearStartMonth = 1;
 
    public GrafanaTimeParser() {}
 
    public GrafanaTimeParser(DayOfWeek weekStart, int fiscalYearStartMonth) {
        this.weekStart = weekStart;
        this.fiscalYearStartMonth = fiscalYearStartMonth;
    }
 
    // ---------------------------------------------------------------------
    // 공개 API
    // ---------------------------------------------------------------------
 
    /** from 용 기본 파싱: roundUp=false, UTC. 파싱 실패 시 null. */
    public ZonedDateTime parse(String text) {
        return parse(text, false, ZoneId.of("UTC"));
    }
 
    /** from 은 roundUp=false, to 는 roundUp=true 로 호출. */
    public ZonedDateTime parse(String text, boolean roundUp, ZoneId zone) {
        return parse(text, roundUp, zone, ZonedDateTime.now(zone));
    }
 
    /** now 를 외부에서 주입할 수 있는 버전(테스트/재현 용도). */
    public ZonedDateTime parse(String text, boolean roundUp, ZoneId zone, ZonedDateTime now) {
        if (text == null || text.isEmpty()) {
            return null;
        }
 
        ZonedDateTime time;
        String mathString;
 
        if (text.startsWith("now")) {
            time = now.withZoneSameInstant(zone);
            mathString = text.substring("now".length());
        } else {
            int idx = text.indexOf("||");
            String parseString;
            if (idx == -1) {
                parseString = text;
                mathString = "";
            } else {
                parseString = text.substring(0, idx);
                mathString = text.substring(idx + 2);
            }
            time = parseAbsolute(parseString.trim(), zone);
            if (time == null) {
                return null;
            }
        }
 
        if (mathString.isEmpty()) {
            return time;
        }
        return parseDateMath(mathString, time, roundUp);
    }
 
    /** 편의 메서드: epoch milliseconds 로 반환. 실패 시 null. */
    public Long parseToEpochMilli(String text, boolean roundUp, ZoneId zone) {
        ZonedDateTime z = parse(text, roundUp, zone);
        return z == null ? null : z.toInstant().toEpochMilli();
    }
 
    // ---------------------------------------------------------------------
    // 절대 시각 파싱 (epoch ms / ISO-8601)
    // ---------------------------------------------------------------------
 
    private ZonedDateTime parseAbsolute(String s, ZoneId zone) {
        if (s.isEmpty()) {
            return null;
        }
 
        // epoch milliseconds
        if (s.matches("[+-]?\\d+")) {
            try {
                return Instant.ofEpochMilli(Long.parseLong(s)).atZone(zone);
            } catch (NumberFormatException e) {
                return null;
            }
        }
 
        // 오프셋/Z 가 포함된 형식: 2021-01-01T00:00:00Z, ...+09:00
        try {
            return OffsetDateTime.parse(s).atZoneSameInstant(zone);
        } catch (DateTimeParseException ignored) { /* 다음 형식 시도 */ }
 
        // 오프셋 없는 로컬 날짜시각 → 주어진 zone 으로 해석
        try {
            return LocalDateTime.parse(s).atZone(zone);
        } catch (DateTimeParseException ignored) { /* 다음 형식 시도 */ }
 
        // 공백 구분 "yyyy-MM-dd HH:mm:ss"
        try {
            DateTimeFormatter f = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
            return LocalDateTime.parse(s, f).atZone(zone);
        } catch (DateTimeParseException ignored) { /* 다음 형식 시도 */ }
 
        // 날짜만 "yyyy-MM-dd"
        try {
            return LocalDate.parse(s).atStartOfDay(zone);
        } catch (DateTimeParseException ignored) { /* 실패 */ }
 
        return null;
    }
 
    // ---------------------------------------------------------------------
    // date math 파싱 ("-1d/d+12h" 같은 문자열)
    // ---------------------------------------------------------------------
 
    private ZonedDateTime parseDateMath(String mathString, ZonedDateTime time, boolean roundUp) {
        String s = mathString.replaceAll("\\s", "");
        ZonedDateTime dt = time;
        int i = 0;
        int len = s.length();
 
        while (i < len) {
            char c = s.charAt(i++);
            int type; // 0=round, 1=add, 2=subtract
            if (c == '/') {
                type = 0;
            } else if (c == '+') {
                type = 1;
            } else if (c == '-') {
                type = 2;
            } else {
                return null; // 잘못된 연산자
            }
 
            // 숫자 파싱 (없으면 1)
            long num;
            if (i < len && Character.isDigit(s.charAt(i))) {
                int from = i;
                while (i < len && Character.isDigit(s.charAt(i))) {
                    i++;
                    if (i - from > 10) {
                        return null; // 너무 긴 숫자 → 무효 (Grafana 와 동일)
                    }
                }
                num = Long.parseLong(s.substring(from, i));
            } else {
                num = 1;
            }
 
            // 반올림(/)은 숫자를 받지 않음
            if (type == 0 && num != 1) {
                return null;
            }
 
            if (i >= len) {
                return null; // 단위 없음
            }
            char unit = s.charAt(i++);
 
            // 회계(fiscal) 접두사: fy, fQ
            boolean isFiscal = false;
            if (unit == 'f') {
                if (i >= len) {
                    return null;
                }
                unit = s.charAt(i++);
                isFiscal = true;
            }
 
            if (!isValidUnit(unit, isFiscal)) {
                return null;
            }
 
            switch (type) {
                case 0:
                    dt = roundUp ? endOf(dt, unit, isFiscal) : startOf(dt, unit, isFiscal);
                    break;
                case 1:
                    dt = add(dt, num, unit);
                    break;
                default:
                    dt = add(dt, -num, unit);
                    break;
            }
            if (dt == null) {
                return null;
            }
        }
        return dt;
    }
 
    private boolean isValidUnit(char unit, boolean isFiscal) {
        if (isFiscal) {
            return unit == 'y' || unit == 'Q'; // fy, fQ 만 지원
        }
        return "yMwdhmsQ".indexOf(unit) >= 0;
    }
 
    // ---------------------------------------------------------------------
    // 더하기 / 빼기
    // ---------------------------------------------------------------------
 
    private ZonedDateTime add(ZonedDateTime dt, long num, char unit) {
        switch (unit) {
            case 's': return dt.plusSeconds(num);
            case 'm': return dt.plusMinutes(num);
            case 'h': return dt.plusHours(num);
            case 'd': return dt.plusDays(num);
            case 'w': return dt.plusWeeks(num);
            case 'M': return dt.plusMonths(num);
            case 'Q': return dt.plusMonths(num * 3);
            case 'y': return dt.plusYears(num);
            default:  return null;
        }
    }
 
    // ---------------------------------------------------------------------
    // 단위 시작으로 스냅 (roundUp=false)
    // ---------------------------------------------------------------------
 
    private ZonedDateTime startOf(ZonedDateTime dt, char unit, boolean isFiscal) {
        if (isFiscal) {
            return unit == 'y' ? startOfFiscalYear(dt) : startOfFiscalQuarter(dt);
        }
        ZoneId z = dt.getZone();
        switch (unit) {
            case 's': return dt.truncatedTo(ChronoUnit.SECONDS);
            case 'm': return dt.truncatedTo(ChronoUnit.MINUTES);
            case 'h': return dt.truncatedTo(ChronoUnit.HOURS);
            case 'd': return dt.toLocalDate().atStartOfDay(z);
            case 'w': return dt.toLocalDate()
                                .with(TemporalAdjusters.previousOrSame(weekStart))
                                .atStartOfDay(z);
            case 'M': return dt.toLocalDate().withDayOfMonth(1).atStartOfDay(z);
            case 'y': return dt.toLocalDate().withDayOfYear(1).atStartOfDay(z);
            case 'Q': {
                int qStartMonth = ((dt.getMonthValue() - 1) / 3) * 3 + 1;
                return dt.toLocalDate().withMonth(qStartMonth).withDayOfMonth(1).atStartOfDay(z);
            }
            default: return null;
        }
    }
 
    // ---------------------------------------------------------------------
    // 단위 끝으로 스냅 (roundUp=true) — moment 의 endOf 처럼 마지막 ms
    // ---------------------------------------------------------------------
 
    private ZonedDateTime endOf(ZonedDateTime dt, char unit, boolean isFiscal) {
        ZonedDateTime start = startOf(dt, unit, isFiscal);
        if (start == null) {
            return null;
        }
        ZonedDateTime next;
        if (isFiscal) {
            next = (unit == 'y') ? start.plusYears(1) : start.plusMonths(3);
        } else {
            next = add(start, 1, unit);
        }
        return next.minus(1, ChronoUnit.MILLIS);
    }
 
    // ---------------------------------------------------------------------
    // 회계연도/분기
    // ---------------------------------------------------------------------
 
    private ZonedDateTime startOfFiscalYear(ZonedDateTime dt) {
        LocalDate date = dt.toLocalDate();
        LocalDate fyStart = LocalDate.of(date.getYear(), fiscalYearStartMonth, 1);
        if (date.isBefore(fyStart)) {
            fyStart = fyStart.minusYears(1);
        }
        return fyStart.atStartOfDay(dt.getZone());
    }
 
    private ZonedDateTime startOfFiscalQuarter(ZonedDateTime dt) {
        ZonedDateTime fyStart = startOfFiscalYear(dt);
        long months = ChronoUnit.MONTHS.between(
                fyStart.toLocalDate().withDayOfMonth(1),
                dt.toLocalDate().withDayOfMonth(1));
        long q = months / 3;
        return fyStart.plusMonths(q * 3);
    }
 
    // ---------------------------------------------------------------------
    // 데모 / 자체 테스트
    // ---------------------------------------------------------------------
 
    public static void main(String[] args) {
        ZoneId zone = ZoneId.of("Asia/Seoul");
        GrafanaTimeParser parser = new GrafanaTimeParser();
 
        // 결과를 재현 가능하게 now 를 고정
        ZonedDateTime now = ZonedDateTime.of(2024, 3, 15, 14, 37, 25, 0, zone);
        DateTimeFormatter out = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS XXX");
 
        String[] inputs = {
            "now",
            "now-5m",
            "now-1h",
            "now-1h/h",
            "now-1d",
            "now/d",
            "now-1d/d",
            "now/w",
            "now-1w/w",
            "now/M",
            "now-1M/M",
            "now/y",
            "now/Q",
            "now-3d/d+9h",
            "now+1d",
            "now/fy",          // 회계연도 시작 (기본 1월 → 달력연도와 동일)
            "1609459200000",   // epoch ms (2021-01-01 00:00 UTC)
            "2021-06-15T03:30:00Z",
            "2021-06-15T12:30:00+09:00",
            "2021-06-15 12:30:00",
            "2021-06-15",
            "2021-06-15T00:00:00Z||+1d/d",
            "쓰레기값"
        };
 
        System.out.println("기준 now = " + now.format(out));
        System.out.println("zone     = " + zone + "  (roundUp=false, from 기준)\n");
 
        for (String in : inputs) {
            ZonedDateTime r = parser.parse(in, false, zone, now);
            System.out.printf("%-34s -> %s%n",
                    in, r == null ? "(파싱 실패 / null)" : r.format(out));
        }
 
        // roundUp=true (to 기준) 비교 예시
        System.out.println("\n[roundUp=true, to 기준]");
        for (String in : new String[]{"now/d", "now/M", "now/w", "now/y"}) {
            ZonedDateTime r = parser.parse(in, true, zone, now);
            System.out.printf("%-34s -> %s%n", in, r.format(out));
        }
    }
}
