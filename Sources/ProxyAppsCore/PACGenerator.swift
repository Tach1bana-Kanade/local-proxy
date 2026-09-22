import Foundation
import CryptoKit

public enum PACGenerator {
    public static func generate(websites: [ManagedWebsite]) -> String { generate(mode: .manual, manual: websites) }
    public static func shouldProxy(host: String, websites: [ManagedWebsite]) -> Bool {
        DomainRuleMatcher(manual: websites).decision(host: host, mode: .manual).action == .proxy
    }
    public static func revision(_ content: String) -> String { SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func generate(mode: RoutingMode, manual: [ManagedWebsite], automatic: [DomainRule] = []) -> String {
        let matcher = DomainRuleMatcher(manual: mode == .off ? [] : manual, automatic: mode == .smart ? automatic : [])
        func encode(_ index: [String: RuleAction]) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return String(data: try! encoder.encode(index.mapValues { $0 == .direct ? 1 : 2 }), encoding: .utf8)!
        }
        return """
        var manualRules = \(encode(matcher.manual));
        var autoRules = decodeRules(\(packedAutomatic(matcher.automatic)));
        // Decode once when the PAC is loaded. Per-request lookup still uses the domain index.
        function decodeRules(text) {
          var rules={}, pos=0, previous='';
          while(pos<text.length) {
            var end=text.indexOf(':',pos), prefix=parseInt(text.substring(pos,end),36); pos=end+1;
            end=text.indexOf(':',pos); var size=parseInt(text.substring(pos,end),36); pos=end+1;
            var key=previous.substring(0,prefix)+text.substr(pos,size); pos+=size;
            rules[key.split('').reverse().join('')]=+text.charAt(pos++); previous=key;
          }
          return rules;
        }
        function localV4(h) {
          var p = h.split('.');
          if (p.length !== 4) return false;
          for (var i=0;i<4;i++) if (!/^\\d+$/.test(p[i]) || +p[i]>255) return false;
          var a=+p[0], b=+p[1];
          return a===0 || a===10 || a===127 || (a===169 && b===254) ||
            (a===172 && b>=16 && b<=31) || (a===192 && b===168) ||
            (a===100 && b>=64 && b<=127) || a>=224;
        }
        function localHost(h) {
          if (h.indexOf('.')<0 && h.indexOf(':')<0 || /\\.(local|lan|localhost)$/.test(h) || h==='home.arpa' || /\\.home\\.arpa$/.test(h)) return true;
          if (localV4(h)) return true;
          if (h.indexOf(':')<0) return false;
          var tail=h.substring(h.lastIndexOf(':')+1);
          if (tail.indexOf('.')>=0) {
            var p=tail.split('.');
            if(p.length!==4) return false;
            h=h.substring(0,h.lastIndexOf(':')+1)+((+p[0]*256)+(+p[1])).toString(16)+':'+((+p[2]*256)+(+p[3])).toString(16);
          }
          var halves=h.split('::'), left=halves[0] ? halves[0].split(':') : [], right=halves.length>1 && halves[1] ? halves[1].split(':') : [];
          if(halves.length>1) { while(left.length+right.length<8) left.push('0'); left=left.concat(right); }
          if(left.length!==8) return false;
          var v=[]; for(var j=0;j<8;j++) v.push(parseInt(left[j],16));
          var zero=true; for(var k=0;k<7;k++) if(v[k]!==0) zero=false;
          if(zero) return true;
          var mapped=true; for(var m=0;m<5;m++) if(v[m]!==0) mapped=false;
          if(mapped && v[5]===65535) return localV4([v[6]>>8,v[6]&255,v[7]>>8,v[7]&255].join('.'));
          if(mapped && v[5]===0) return true;
          return (v[0]&65024)===64512 || (v[0]&65472)===65152 || (v[0]&65280)===65280;
        }
        function lookup(h, rules) {
          var value=rules['e:'+h]; if(value) return value;
          while(true) {
            value=rules['s:'+h]; if(value) return value;
            var dot=h.indexOf('.'); if(dot<0) return 0; h=h.substring(dot+1);
          }
        }
        function FindProxyForURL(url, host) {
          host=host.toLowerCase().replace(/^[\\[.]+|[\\].]+$/g,'');
          if(localHost(host)) return "DIRECT";
          var result=lookup(host,manualRules) || lookup(host,autoRules);
          if(result===2) return "PROXY 127.0.0.1:21081";
          return "DIRECT";
        }
        """
    }
    /// Automatic rules only: DIRECT is already the default. Elide rules with the same
    /// action as their inherited suffix, preserving every exception and exact boundary.
    /// Keep the full RuleSet/Swift matcher for classification explanations in the UI.
    private static func packedAutomatic(_ index: [String: RuleAction]) -> String {
        func inherited(_ domain: String, includeSelf: Bool) -> RuleAction {
            var name = domain
            if includeSelf, let action = index["s:" + name] { return action }
            while let dot = name.firstIndex(of: ".") {
                name = String(name[name.index(after: dot)...])
                if let action = index["s:" + name] { return action }
            }
            return .direct
        }
        let entries = index.compactMap { key, action -> (String, RuleAction)? in
            let domain = String(key.dropFirst(2))
            guard action != inherited(domain, includeSelf: key.hasPrefix("e:")) else { return nil }
            return (String(key.reversed()), action)
        }.sorted { $0.0 < $1.0 }
        var previous: [UInt16] = [], packed = ""
        for (key, action) in entries {
            let units = Array(key.utf16)
            var prefix = 0
            while prefix < min(previous.count, units.count), previous[prefix] == units[prefix] { prefix += 1 }
            let tail = String(decoding: units.dropFirst(prefix), as: UTF16.self)
            packed += String(prefix, radix: 36) + ":" + String(units.count - prefix, radix: 36) + ":" + tail + (action == .direct ? "1" : "2")
            previous = units
        }
        let encoder = JSONEncoder()
        // Encoding a String has no failing values; JSON prevents data from becoming JavaScript.
        return String(data: try! encoder.encode(packed), encoding: .utf8)!
    }

}
